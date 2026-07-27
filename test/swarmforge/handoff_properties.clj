(ns swarmforge.handoff-properties
  (:require [babashka.fs :as fs]
            [clojure.string :as str]
            [clojure.test :refer [deftest is run-tests use-fixtures]]
            [clojure.test.check :as tc]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]))

(def repo-root (fs/cwd))

(load-file (str (fs/path repo-root "swarmforge" "scripts" "handoff_lib.bb")))

(def temp-dirs (atom []))

(use-fixtures :once
  (fn [tests]
    (try
      (tests)
      (finally
        (doseq [dir @temp-dirs]
          (fs/delete-tree dir))))))

(defn tmp-dir []
  (let [dir (fs/create-temp-dir {:prefix "swarmforge-handoff-props."})]
    (swap! temp-dirs conj dir)
    dir))

;; ── Generators ────────────────────────────────────────────────────

(def field-gen
  (gen/fmap (fn [[c cs]] (apply str c cs))
            (gen/tuple gen/char-alpha
                       (gen/vector (gen/elements (vec "abcdefghijklmnopqrstuvwxyz0123456789_-")) 0 12))))

(def value-gen
  (gen/fmap str/join
            (gen/vector (gen/elements (vec "abcdefghijklmnopqrstuvwxyz ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.,:/-_"))
                        0 30)))

(def headers-gen
  (gen/fmap #(into {} %)
            (gen/vector-distinct-by first
                                    (gen/tuple field-gen value-gen)
                                    {:min-elements 1 :max-elements 6 :max-tries 50})))

(def body-lines-gen
  (gen/vector (gen/one-of [value-gen (gen/return "")]) 0 8))

(defn render-handoff [headers body-lines]
  (str (str/join "\n" (for [[f v] headers] (str f ": " v)))
       "\n\n"
       (str/join "\n" body-lines)
       "\n"))

(defn write-handoff! [dir headers body-lines]
  (let [file (fs/path dir (str (gensym "prop") ".handoff"))]
    (spit (str file) (render-handoff headers body-lines))
    file))

;; ── Properties ────────────────────────────────────────────────────

(def render-parse-round-trip
  (prop/for-all [headers headers-gen
                 body-lines body-lines-gen]
    (let [dir (tmp-dir)
          file (write-handoff! dir headers body-lines)
          expected-body (str (str/join "\n" body-lines) "\n")]
      (and (every? (fn [[f v]] (= v (handoff-lib/header-field file f))) headers)
           (= expected-body (handoff-lib/body file))))))

(def set-header-round-trip
  (prop/for-all [headers headers-gen
                 body-lines body-lines-gen
                 fresh-field field-gen
                 new-value value-gen
                 pick-existing? gen/boolean]
    (let [dir (tmp-dir)
          file (write-handoff! dir headers body-lines)
          target (if (and pick-existing? (seq headers))
                   (key (first headers))
                   fresh-field)
          before-body (handoff-lib/body file)]
      (handoff-lib/set-header! file target new-value)
      (let [after-once (slurp (str file))]
        (handoff-lib/set-header! file target new-value)
        (and (= new-value (handoff-lib/header-field file target))
             (every? (fn [[f v]] (or (= f target)
                                     (= v (handoff-lib/header-field file f))))
                     headers)
             (= before-body (handoff-lib/body file))
             (= after-once (slurp (str file))))))))

(def epoch-gen (gen/choose 1500000000 4000000000))

(defn id-timestamp-str [epoch-sec]
  (.format (java.time.format.DateTimeFormatter/ofPattern "yyyyMMdd'T'HHmmss'Z'")
           (java.time.ZonedDateTime/ofInstant (java.time.Instant/ofEpochSecond epoch-sec)
                                              java.time.ZoneOffset/UTC)))

(def queue-entry-gen
  (gen/tuple (gen/choose 0 99) epoch-gen (gen/choose 1 999999)))

(def queue-order-matches-semantic-order
  (prop/for-all [entries (gen/vector-distinct queue-entry-gen {:min-elements 1 :max-elements 15})]
    (let [dir (tmp-dir)
          filename (fn [[priority epoch seq-num]]
                     (format "%02d_%s_%06d_from_sender_to_receiver.handoff"
                             priority (id-timestamp-str epoch) seq-num))
          filenames (map filename entries)
          semantic (map filename (sort-by (fn [[p e s]] [p e s]) entries))]
      (doseq [name (shuffle filenames)]
        (spit (str (fs/path dir name)) ""))
      (spit (str (fs/path dir "notes.txt")) "ignored")
      (fs/create-dirs (fs/path dir "subdir"))
      (and (= semantic (sort filenames))
           (= semantic (map fs/file-name (handoff-lib/handoff-files dir)))))))

(def sequence-counter-monotonic
  (prop/for-all [initial (gen/one-of [(gen/choose 0 500000)
                                      (gen/elements ["" "garbage" "12ab" "-5"])])
                 calls (gen/choose 1 15)]
    (let [dir (tmp-dir)
          original-user-dir (System/getProperty "user.dir")]
      (try
        (System/setProperty "user.dir" (str dir))
        (let [seq-dir (fs/path dir ".swarmforge" "handoffs")
              start (if (integer? initial) initial 0)]
          (fs/create-dirs seq-dir)
          (spit (str (fs/path seq-dir "sequence")) (str initial "\n"))
          (let [results (vec (repeatedly calls handoff-lib/next-sequence))
                numbers (mapv #(Long/parseLong %) results)]
            (and (every? #(re-matches #"[0-9]{6}" %) results)
                 (apply < (cons start numbers))
                 (= (+ start calls) (peek numbers)))))
        (finally
          (System/setProperty "user.dir" original-user-dir))))))

;; ── Test harness ──────────────────────────────────────────────────

(defn check [prop trials label]
  (let [result (tc/quick-check trials prop)]
    (is (:pass? result) (str label ": " (pr-str result)))))

(deftest render-parse-round-trip-property
  (check render-parse-round-trip 100 "render/parse round trip"))

(deftest set-header-round-trip-property
  (check set-header-round-trip 100 "set-header! round trip"))

(deftest queue-order-property
  (check queue-order-matches-semantic-order 50 "queue order matches semantic order"))

(deftest sequence-counter-property
  (check sequence-counter-monotonic 30 "sequence counter monotonic"))

(defn -main [& _]
  (let [{:keys [fail error]} (run-tests 'swarmforge.handoff-properties)]
    (System/exit (+ fail error))))
