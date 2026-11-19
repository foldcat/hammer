package main

import "core:sys/linux"

ignore_termination :: proc() {
	action := linux.Sig_Action{special = .SIG_IGN}
	linux.rt_sigaction(.SIGTERM, &action, nil)
}
