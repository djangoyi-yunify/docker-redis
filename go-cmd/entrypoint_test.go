package main

import (
	"os"
	"testing"
)

func TestGetEndpoint(t *testing.T) {
	// endpointList := os.Getenv("ENDPOINT_LIST")
	err := os.Setenv("ENDPOINT_LIST", "node-dev:6470:88")
	if err != nil {
		t.Fatal(err)

	}
	os.Setenv("HOSTNAME", "asdafsdfasdf")
	// t.Log(os.Getenv("ENDPOINT_LIST"))
	t.Log(getEndpoint("localhost"))

}

func TestEntrypoint(t *testing.T) {
	entrypoint()
}
