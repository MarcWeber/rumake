smart make like build system for Ruby
=====================================

make for ruby rewritten (experimental)

features:
* fast / lightweight
* abort early
* keep going (optional)
* tries to build the dependency path which is supposed to take longest first
* multiple threads possible to run multiple compilations at the same time
  (no processes, thus if you have long running ruby calculations we have to
  think about a solution)
* estimated time of arrival support by simulating the build based on previous runs
* taks.respond_to? :shell_commands => export to makefile

TODO:
- improve rake/drake like DSL

goals:
write the code in a way so that it can eventually be used by guard one day
