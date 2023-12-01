package main

import (
	"encoding/base64"
	"flag"
	"fmt"
	"os"
	"strings"
)

func base64Decode(text string) string {
	result, _ := base64.StdEncoding.DecodeString(text)
	return string(result)
}

func getRequirepass() string {

	rules, err := runRedisCmd("localhost", "config", "get", "Requirepass")
	if err != nil {
		fmt.Println("config get Requirepass: ", err)
		os.Exit(1)
	}
	rulesList := strings.Split(rules, "\n")
	if len(rulesList) > 1 {
		return rulesList[1]
	}
	return ""

}

func aclLoad(args []string) error {
	var password string
	var aclfilebase64 string
	fmt.Println(args)

	flag.StringVar(&password, "requirepass", getRequirepass(), "string flag value")
	flag.StringVar(&aclfilebase64, "acl-content", "", "string flag value")
	flag.CommandLine.Parse(args)

	// password := base64Decode(passwordbase64)
	aclfile := base64Decode(aclfilebase64)
	aclfileList := []string{}
	aclfileList = append(aclfileList, fmt.Sprintf("user default on %s ~* &* +@all", aclEncrypt(password)))
	measurePassword := getPassword("MEASURE_PASSWORD")
	if measurePassword != "" {
		aclfileList = append(aclfileList, fmt.Sprintf("user measure on %s ~* &* +ping +config +info +acl|load", aclEncrypt(measurePassword)))
	}
	for _, item := range strings.Split(aclfile, "\n") {
		if strings.HasPrefix(item, "user default ") {
			continue
		}
		if strings.HasPrefix(item, "user measure ") {
			continue
		}
		aclfileList = append(aclfileList, item)
	}
	flush(dataDir+"/aclfile.conf", strings.Join(aclfileList, "\n"))
	runRedisCmd("localhost", "config", "set", "requirepass", password)
	runRedisCmd("localhost", "config", "set", "masterauth", password)
	runRedisCmd("localhost", "acl", "load")
	return nil
}

func appctl() {
	if len(os.Args) < 2 {
		fmt.Println("appctl Format error:", os.Args)
		os.Exit(1)
	}
	if os.Args[1] == "aclLoad" {
		aclLoad(os.Args[2:])
	}

}
