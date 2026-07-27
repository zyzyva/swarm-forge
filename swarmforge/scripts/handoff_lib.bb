#!/usr/bin/env bb

(ns handoff-lib
  (:require [babashka.fs :as fs]
            [babashka.process]
            [clojure.string :as str]))

(defn role []
  (or (System/getenv "SWARMFORGE_ROLE")
      (throw (ex-info "Set SWARMFORGE_ROLE." {:exit 1}))))

(defn state-dir []
  (fs/path (System/getProperty "user.dir") ".swarmforge" "handoffs"))

(defn inbox-dir []
  (fs/path (state-dir) "inbox"))

(defn project-root []
  (let [cwd (fs/cwd)
        direct (fs/path cwd ".swarmforge" "roles.tsv")]
    (if (fs/exists? direct)
      cwd
      (let [git-root (:out (babashka.process/sh {:continue true} "git" "rev-parse" "--show-toplevel"))
            root (when-not (str/blank? git-root) (fs/path (str/trim git-root)))]
        (if (and root (fs/exists? (fs/path root ".swarmforge" "roles.tsv")))
          root
          (let [common (:out (babashka.process/sh {:continue true} "git" "rev-parse" "--git-common-dir"))
                common-path (when-not (str/blank? common)
                              (let [path (fs/path (str/trim common))]
                                (if (fs/absolute? path) path (fs/absolutize path))))
                common-parent (some-> common-path fs/parent)]
            (if (and common-parent (fs/exists? (fs/path common-parent ".swarmforge" "roles.tsv")))
              common-parent
              (throw (ex-info "Cannot find SwarmForge project root" {:exit 1})))))))))

(defn roles-file []
  (fs/path (project-root) ".swarmforge" "roles.tsv"))

(defn role-rows []
  (->> (str/split-lines (slurp (str (roles-file))))
       (map #(str/split % #"\t" -1))))

(defn role-row [role-name]
  (or (some #(when (= role-name (first %)) %) (role-rows))
      (throw (ex-info (str "Unknown role: " role-name) {:exit 1}))))

(defn role-known? [role-name]
  (boolean (some #(= role-name (first %)) (role-rows))))

(defn role-worktree-name [role-name]
  (second (role-row role-name)))

(defn role-receive-mode [role-name]
  (let [mode (nth (role-row role-name) 6 "")]
    (if (str/blank? mode) "task" mode)))

(defn timestamp []
  (.format java.time.format.DateTimeFormatter/ISO_INSTANT
           (java.time.Instant/now)))

(defn id-timestamp []
  (.format (java.time.format.DateTimeFormatter/ofPattern "yyyyMMdd'T'HHmmss'Z'")
           (java.time.ZonedDateTime/now java.time.ZoneOffset/UTC)))

(defn valid-priority? [value]
  (boolean (re-matches #"[0-9][0-9]" value)))

(defn header-field [file field]
  (let [prefix (str field ": ")]
    (some (fn [line]
            (when (str/starts-with? line prefix)
              (subs line (count prefix))))
          (take-while (complement str/blank?)
                      (str/split-lines (slurp (str file)))))))

(defn body [file]
  (let [[_ body] (str/split (slurp (str file)) #"\n\n" 2)]
    (or body "")))

(defn set-header! [file field value]
  (let [file (fs/path file)
        content (slurp (str file))
        [headers handoff-body] (str/split content #"\n\n" 2)
        prefix (str field ": ")
        header-lines (vec (remove #(= "" %) (str/split-lines (or headers ""))))
        replaced (mapv #(if (str/starts-with? % prefix) (str prefix value) %) header-lines)
        new-headers (if (some #(str/starts-with? % prefix) header-lines)
                      replaced
                      (conj replaced (str prefix value)))
        tmp (fs/create-temp-file {:dir (fs/parent file) :prefix ".headers."})]
    (spit (str tmp) (str (str/join "\n" new-headers)
                         (if handoff-body (str "\n\n" handoff-body) "\n")))
    (fs/move tmp file {:replace-existing true})))

(defn print-task [file]
  (let [task-name (header-field file "task")]
    (println "TASK:" (str file))
    (println "FROM:" (or (header-field file "from") "unknown"))
    (println "TYPE:" (or (header-field file "type") "unknown"))
    (println "PRIORITY:" (or (header-field file "priority") "50"))
    (when task-name
      (println "TASK_NAME:" task-name))
    (println "PAYLOAD:")
    (print (body file))))

(defn handoff-files [dir]
  (if (fs/exists? dir)
    (->> (fs/list-dir dir)
         (filter #(and (fs/regular-file? %) (str/ends-with? (fs/file-name %) ".handoff")))
         (sort-by #(fs/file-name %))
         vec)
    []))

(defn print-batch [batch-dir]
  (let [files (handoff-files batch-dir)]
    (when (empty? files)
      (throw (ex-info (str "AMBIGUOUS_TASK_STATE: batch contains no tasks: " batch-dir) {:exit 2})))
    (println "BATCH:" (str batch-dir))
    (println "COUNT:" (count files))
    (println "PRIORITY:" (or (header-field (first files) "priority") "50"))
    (doseq [[index file] (map-indexed vector files)]
      (println)
      (println "BATCH_ITEM:" (inc index))
      (print-task file))))

(defn next-sequence []
  (let [dir (state-dir)
        seq-file (fs/path dir "sequence")
        lock-dir (fs/path dir "sequence.lock")]
    (fs/create-dirs dir)
    (loop []
      (when-not (try (fs/create-dir lock-dir) true (catch Exception _ false))
        (Thread/sleep 50)
        (recur)))
    (try
      (let [last-value (if (fs/exists? seq-file)
                         (str/trim (slurp (str seq-file)))
                         "0")
            last-number (if (re-matches #"[0-9]+" last-value)
                          (Long/parseLong last-value)
                          0)
            next-number (inc last-number)]
        (spit (str seq-file) (format "%06d\n" next-number))
        (format "%06d" next-number))
      (finally
        (fs/delete-tree lock-dir)))))

(defn -main [& args]
  (try
    (case (first args)
      "role" (println (role))
      "state-dir" (println (state-dir))
      "inbox-dir" (println (inbox-dir))
      "project-root" (println (project-root))
      "role-known" (System/exit (if (role-known? (second args)) 0 1))
      "role-worktree-name" (println (role-worktree-name (second args)))
      "role-receive-mode" (println (role-receive-mode (second args)))
      "timestamp" (println (timestamp))
      "id-timestamp" (println (id-timestamp))
      "valid-priority" (System/exit (if (valid-priority? (second args)) 0 1))
      "header-field" (if-let [value (header-field (second args) (nth args 2))]
                       (println value)
                       (System/exit 1))
      "body" (print (body (second args)))
      "set-header" (set-header! (second args) (nth args 2) (nth args 3))
      "print-task" (print-task (second args))
      "print-batch" (print-batch (second args))
      "next-sequence" (println (next-sequence))
      (do
        (binding [*out* *err*]
          (println "Usage: handoff_lib.bb <command> [args...]"))
        (System/exit 2)))
    (catch clojure.lang.ExceptionInfo e
      (binding [*out* *err*]
        (println (ex-message e)))
      (System/exit (or (:exit (ex-data e)) 1)))))

(when (= *file* (System/getProperty "babashka.file"))
  (apply -main *command-line-args*))
