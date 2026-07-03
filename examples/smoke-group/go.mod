module github.com/sunchao1/hi-im/examples/smoke-group

go 1.22

require (
	github.com/gorilla/websocket v1.5.3
	github.com/sunchao1/hi-im-api v0.1.0
	google.golang.org/protobuf v1.34.1
)

replace github.com/sunchao1/hi-im-api => ../../../hi-im-api
