package main

import (
	"os"
	"runtime"
	"strings"
)

const (
	dataDir string = "/data/redis"
	confDir string = "/etc/redis"
	runUid  int    = 999
	runGid  int    = 1000

// const runUser string = "redis"
)

func init() {
	// make sure we only have one process and that it runs on the main thread (so that ideally, when we Exec, we keep our user switches and stuff)
	runtime.GOMAXPROCS(1)
	runtime.LockOSThread()
}

func main() {
	if strings.HasSuffix(os.Args[0], "entrypoint") {
		entrypoint()
	} else if strings.HasSuffix(os.Args[0], "healthcheck") {
		healthcheck()
	} else if strings.HasSuffix(os.Args[0], "appctl") {
		appctl()
	}

}
