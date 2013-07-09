smart make like build system for Ruby
=====================================

make for ruby rewritten (experimental)

features:
* abort early
* keep going (optional)
* tries to build the dependency path which is supposed to take longest first
* no processes, based but multiple threads (which is fine if you run compilers
  anyway)
* estimated time of arrival support by simulating the build


TODO:
- rake like DSL
- provide make file abstraction


goals:
write the code in a way so that it can eventually be used by guard one day
