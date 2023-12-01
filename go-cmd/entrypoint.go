package main

import (
	"bufio"
	"crypto/sha256"
	"fmt"
	"io"
	"os"
	"runtime"
	"strconv"
	"strings"
	"syscall"
)

func buildDisableCommand(cmd string) string {
	disableCmds := strings.ToUpper(fmt.Sprintf(" %s ", os.Getenv("DISABLE_CMDS")))
	cmdExtension := strings.ToUpper(fmt.Sprintf(" %s ", cmd))
	if os.Getenv("SETUP_MODE") != "sentinel" && strings.Contains(disableCmds, cmdExtension) {
		clusterName := os.Getenv("CLUSTER_NAME")
		nameSpace := os.Getenv("NAME_SPACE")
		return sha256sum(fmt.Sprintf("%s.%s.%s", cmd, clusterName, nameSpace))
	}
	return cmd
}

func aclEncrypt(test string) string {
	if test == "" {
		return "nopass"
	}
	return "#" + sha256sum(test)
}

func sha256sum(text string) string {
	sum := sha256.Sum256([]byte(text))
	return fmt.Sprintf("%x", sum)
}

func readFile(filename string) []string {
	_, err := os.Stat(filename)
	if os.IsNotExist(err) {
		return []string{}
	}
	content, err := os.ReadFile(filename)
	if err != nil {
		fmt.Println(err)
		return []string{}
	}
	text := string(content)
	return strings.Split(text, "\n")
}

func copy(src, dst string) (int64, error) {
	dstWriter, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE, 0666)
	if err != nil {
		return 0, err
	}

	defer os.Chown(dst, runUid, runGid)
	defer dstWriter.Close()
	srcReader, err := os.Open(src)
	if err != nil {
		return 0, err
	}
	defer srcReader.Close()
	return io.Copy(dstWriter, srcReader)
}

func flush(filePath string, text string) error {
	filePaths := []string{filePath}
	for i := 1; i < 20; i++ {
		filePaths = append(filePaths, fmt.Sprintf("%s.%d", filePath, i))
	}
	for i := len(filePaths) - 1; i > 0; i-- {
		src := filePaths[i-1]
		dst := filePaths[i]
		_, err := os.Stat(src)
		if os.IsNotExist(err) {
			continue
		}
		if _, err := copy(src, dst); err != nil {
			fmt.Println(err)
		}
	}
	file, err := os.OpenFile(filePath, os.O_WRONLY|os.O_CREATE, 0600)
	if err != nil {
		fmt.Println("File open failed: ", err)
		return err
	}
	write := bufio.NewWriter(file)
	write.WriteString(text)
	write.WriteString("\n")
	err = write.Flush()
	if err != nil {
		return err
	}
	defer file.Close()
	if os.Getuid() == 0 {
		if err := os.Chown(filePath, runUid, runGid); err != nil {
			fmt.Println("Failed to set mode: ", err)
			return err
		}
	}
	return nil
}

func getEndpoint(hostname string) (port, tlsPort int) {
	if hostname == "localhost" || hostname == "127.0.0.1" {
		hostname, _ = os.Hostname()
		if os.Getenv("SETUP_MODE") == "sentinel" {
			return 26379, 0
		}
	}
	endpointNodeList := os.Getenv("ENDPOINT_LIST")
	nodeList := strings.Split(endpointNodeList, " ")
	for _, endpoint := range nodeList {
		if strings.HasPrefix(endpoint, hostname+".") {
			if items := strings.Split(endpoint, ":"); len(items) > 2 {
				port, err := strconv.Atoi(items[1])
				if err != nil {
					break
				}
				tlsPort, err := strconv.Atoi(items[2])
				if err != nil {
					break
				}
				return port, tlsPort
			}
		}
	}
	return 6379, 0
}

func readExternalConf() []string {
	extConf := readFile(confDir + "/external.conf.d/redis-external.conf")
	outConf := []string{}

	for _, item := range extConf {
		if strings.HasPrefix(item, "logfile ") {
			continue
		}
		outConf = append(outConf, item)
	}
	return outConf
}

func updateAclfileConfig() error {
	aclfile := []string{}
	requirepass := getPassword("REDIS_PASSWORD")
	aclfile = append(aclfile, fmt.Sprintf("user default on %s ~* &* +@all", aclEncrypt(requirepass)))

	measurePassword := getPassword("MEASURE_PASSWORD")
	if measurePassword != "" {
		sha256Requirepass := aclEncrypt(measurePassword)
		aclfile = append(aclfile, fmt.Sprintf("user measure on %s ~* &* +ping +config +info  +acl|load", sha256Requirepass))
	}

	external := readFile(confDir + "/acl.conf.d/aclfile.conf")
	for _, item := range external {
		if strings.HasPrefix(item, "user default ") {
			continue
		}
		if strings.HasPrefix(item, "user measure ") {
			continue
		}
		aclfile = append(aclfile, item)
	}
	flush(dataDir+"/aclfile.conf", strings.Join(aclfile, "\n"))
	return nil
}

func disableCmdsConfig() []string {
	disableCmdTxt := strings.Trim(os.Getenv("DISABLE_CMDS"), " ")
	result := []string{}
	if disableCmdTxt == "" {
		return result
	}
	for _, disableCmd := range strings.Split(disableCmdTxt, " ") {
		result = append(result, fmt.Sprintf("rename-command %s %s", disableCmd, buildDisableCommand(disableCmd)))
	}
	return result

}

func sentinelConfig() []string {
	retention := map[string]bool{
		"sentinel myid":                    true,
		"sentinel auth-pass":               true,
		"sentinel down-after-milliseconds": true,
		"sentinel monitor":                 true,
	}

	config := []string{
		"port 26379",
		"bind 0.0.0.0",
		"daemonize no",
		"logfile \"\"",
		fmt.Sprintf("dir \"%s\"", dataDir),
		"acllog-max-len 128",
		"SENTINEL deny-scripts-reconfig no",
		"SENTINEL resolve-hostnames no",
		"SENTINEL announce-hostnames no",
		fmt.Sprintf("aclfile %s/aclfile.conf", dataDir),
	}

	oldConfigList := readFile(dataDir + "/sentinel.conf")
	for _, item := range oldConfigList {
		items := strings.Split(item, " ")
		if len(items) <= 2 {
			continue
		}
		pre := strings.Join(items[:2], " ")
		if retention[pre] {
			config = append(config, item)
		}
	}

	return config
}

func replicasConfig() []string {
	hostname, _ := os.Hostname()
	port, tlsPort := getEndpoint(hostname)

	externalConf := readFile(confDir + "/external.conf.d/redis-external.conf")
	logFile := fmt.Sprintf("%s/logs/redis-server.log", dataDir)

	for _, item := range externalConf {
		if !strings.HasPrefix(item, "logfile ") {
			continue
		}
		if strings.Contains(item, " stdout") {
			logFile = ""
			break
		}
	}

	config := []string{}
	externalConfFile := fmt.Sprintf("%s/redis-external.conf", dataDir)
	_, err := os.Stat(externalConfFile)
	if os.IsExist(err) {
		config = append(config, "include "+externalConfFile)
	}

	config = append(config,
		"bind 0.0.0.0",
		fmt.Sprintf("port %d", port),
		fmt.Sprintf("tls-port %d", tlsPort),
		"aof-rewrite-incremental-fsync yes",
		"appendfilename appendonly.aof",
		"appendonly yes",
		"auto-aof-rewrite-min-size 64mb",
		"auto-aof-rewrite-percentage 60",
		"daemonize no",
		fmt.Sprintf("dir \"%s\"", dataDir),
		"save \"\"",
		fmt.Sprintf("logfile \"%s\"", logFile),
		fmt.Sprintf("tls-cert-file \"%s/tls/tls.crt\"", dataDir),
		fmt.Sprintf("tls-cert-file \"%s/tls/redis.crt\"", dataDir),
		fmt.Sprintf("tls-key-file \"%s/tls/tls.key\"", dataDir),
		fmt.Sprintf("tls-key-file \"%s/tls/redis.key\"", dataDir),
		fmt.Sprintf("tls-ca-cert-file \"%s/tls/ca.crt\"", dataDir),
		fmt.Sprintf("tls-dh-params-file \"%s/tls/redis.dh\"", dataDir),
		fmt.Sprintf("aclfile %s/aclfile.conf", dataDir),
	)
	if runtime.GOARCH == "arm64" {
		config = append(config, "ignore-warnings ARM64-COW-BUG")
	}
	return config
}

func clusterConfig() []string {
	return []string{
		"cluster-enabled yes",
		"tls-cluster No",
		"cluster-require-full-coverage no",
		"cluster-migration-barrier 5000",
		"cluster-allow-replica-migration no",
		fmt.Sprintf("cluster-config-file \"%s/nodes.conf\"", dataDir),
	}
}

func initNode() {
	dirList := []string{
		dataDir,
		dataDir + "/tls",
		dataDir + "/logs",
	}
	for _, dir := range dirList {
		_, err := os.Stat(dir)
		if os.IsExist(err) {
			continue
		}
		os.Mkdir(dir, 0700)
		os.Chmod(dir, 0700)
		if os.Getuid() == 0 {
			os.Chown(dir, runUid, runGid)
		}
	}
}

func entrypoint() {
	initNode()
	clusterName := os.Getenv("CLUSTER_NAME")

	configList := []string{}
	configfile := dataDir + "/redis.conf"
	cmds := []string{"redis-server", configfile}
	exec := "/usr/local/bin/redis-server"
	updateAclfileConfig()

	setupMode := os.Getenv("SETUP_MODE")
	if setupMode == "sentinel" {
		exec = "/usr/local/bin/redis-sentinel"
		configfile = dataDir + "/sentinel.conf"
		cmds = []string{"redis-sentinel", configfile}
		configList = append(configList, sentinelConfig()...)
		configList = append(configList,
			fmt.Sprintf("sentinel rename-command %s %s %s", clusterName, "CONFIG", buildDisableCommand("CONFIG")),
			fmt.Sprintf("sentinel rename-command %s %s %s", clusterName, "REPLICAOF", buildDisableCommand("REPLICAOF")),
			fmt.Sprintf("sentinel rename-command %s %s %s", clusterName, "SLAVEOF", buildDisableCommand("SLAVEOF")),
		)

	} else {
		configList = append(configList, replicasConfig()...)
		readExternalConfTxt := strings.Join(readExternalConf(), "\n")
		flush(dataDir+"/redis-external.conf", readExternalConfTxt)
		if setupMode == "cluster" {
			configList = append(configList, clusterConfig()...)
		}
		configList = append(configList, disableCmdsConfig()...)
	}

	err := flush(configfile, strings.Join(configList, "\n"))
	if err != nil {
		fmt.Printf("Failed to write \"%s\" file, err: %#v", configfile, err)
	}
	redisPassword := getPassword("REDIS_PASSWORD")
	if redisPassword != "" {
		cmds = append(cmds, "--requirepass", redisPassword)
		cmds = append(cmds, "--masterauth", redisPassword)
	}

	if err := SetupUser(); err != nil {
		fmt.Printf("error: failed switching to %q: %v", runUid, err)
		os.Exit(1)
	}

	if err := syscall.Exec(exec, cmds, os.Environ()); err != nil {
		fmt.Printf("error: exec failed: %v", err)
		os.Exit(1)
	}
}
