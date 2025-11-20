savedcmd_adaptive_sched.mod := printf '%s\n'   adaptive_sched.o | awk '!x[$$0]++ { print("./"$$0) }' > adaptive_sched.mod
