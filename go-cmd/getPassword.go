package main

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/sha256"
	"encoding/base64"
	"fmt"
	"os"
)

func getPassword(text string) string {
	if os.Getenv("REDIS_PASSWORD_ENCRYPT") != "1" {
		return os.Getenv(text)
	}

	encryptCode := os.Getenv(text)
	if encryptCode == "" {
		return ""
	}
	return AesDecrypt(encryptCode)
}

func AesDecrypt(cryted string) string {
	crytedByte, _ := base64.StdEncoding.DecodeString(cryted)
	k := sha256.Sum256([]byte(fmt.Sprintf("%s/%s", os.Getenv("NAME_SPACE"), os.Getenv("CLUSTER_NAME"))))
	block, _ := aes.NewCipher(k[:16])
	blockSize := block.BlockSize()
	blockMode := cipher.NewCBCDecrypter(block, k[:blockSize])
	orig := make([]byte, len(crytedByte))
	blockMode.CryptBlocks(orig, crytedByte)
	orig = PKCS7UnPadding(orig)
	return string(orig)
}

func PKCS7UnPadding(origData []byte) []byte {
	length := len(origData)
	unpadding := int(origData[length-1])
	return origData[:(length - unpadding)]
}
