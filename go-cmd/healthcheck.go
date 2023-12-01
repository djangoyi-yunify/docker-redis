package main

import (
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
)

func execCmd(cmd string, args *[]string) (string, error) {
	fmt.Println(cmd, args)
	cmdobj := exec.Command(cmd, *args...)
	output, err := cmdobj.CombinedOutput()
	stdout := string(output)

	if err != nil {
		return stdout, err
	}
	return stdout, nil
}

func runRedisCmd(host string, cmds ...string) (string, error) {
	runCmds := []string{"-h", host}
	port, _ := getEndpoint(host)
	cmds[0] = buildDisableCommand(cmds[0])
	runCmds = append(runCmds, "-p", strconv.Itoa(port))

	measurePassword := getPassword("MEASURE_PASSWORD")
	if measurePassword != "" {
		runCmds = append(runCmds, "--no-auth-warning", "--user", "measure", "--pass", measurePassword)
	} else {
		requirepass := getPassword("REDIS_PASSWORD")
		if requirepass != "" {
			runCmds = append(runCmds, "--no-auth-warning", "-a", requirepass)
		}
	}
	runCmds = append(runCmds, cmds...)
	return execCmd("redis-cli", &runCmds)
}

func healthcheck() {
	fmt.Println("healthcheck")
	host := "localhost"
	stdout, err := runRedisCmd(host, "PING")
	if err != nil {
		fmt.Printf(`ping "%s" redis failed. %s\n`, host, err)
		os.Exit(1)
	}
	if !strings.Contains(stdout, "PONG") {
		fmt.Printf(`ping "%s" redis failed. %s\n`, host, stdout)
		os.Exit(1)
	}
}
