package main

import (
	"os"

	"github.com/opencontainers/runc/libcontainer/system"
)

// this function comes from libcontainer/init_linux.go
// we don't use that directly because we don't want the whole namespaces package imported here
// (also, because we need minor modifications and it's not even exported)

// SetupUser changes the groups, gid, and uid for the user inside the container
func SetupUser() error {
	if os.Getuid() != 0 {
		return nil
	}
	if err := system.Setgid(runGid); err != nil {
		return err
	}
	if err := system.Setuid(runUid); err != nil {
		return err
	}
	// if we didn't get HOME already, set it based on the user's HOME
	if envHome := os.Getenv("HOME"); envHome == "" {
		if err := os.Setenv("HOME", "/home/redis"); err != nil {
			return err
		}
	}
	return nil
}
