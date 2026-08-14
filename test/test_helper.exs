# `max_cases: 1` -- a real, confirmed finding: this package's three
# real-backend suites (`Scry.Engine.CouchbaseTest`/`Scry.Engine.
# Couchbase.ParityTest`/`Scry.Engine.Couchbase.RelDocTest`) each
# declare `async: false` for their own tests, but ExUnit still runs
# *different* modules' `setup_all` concurrently by default -- three
# independent bucket-provisioning-and-seeding sequences hitting one
# small, single-node dev Couchbase container at once genuinely dropped
# a write under real load (confirmed directly, a document inserted
# during concurrent setup intermittently never became visible even
# under `request_plus` consistency) -- a real resource-contention
# artifact of sharing one small external instance across suites, not a
# bug in the package itself. Forcing full test-run serialization here
# is the same "integration tests against one shared external resource
# should not race each other" reasoning `async: false` already states
# per-module, just applied at the run level too.
ExUnit.configure(max_cases: 1)
ExUnit.start()
