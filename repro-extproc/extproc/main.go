package main

import (
	"flag"
	"io"
	"log"
	"net"
	"os"
	"os/signal"
	"syscall"
	"time"

	ext_proc "github.com/envoyproxy/go-control-plane/envoy/service/ext_proc/v3"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

type server struct {
	name       string
	bodyDelay  time.Duration // delay for ALL body chunk responses
	hdrDelay   time.Duration // delay for response header responses
}

var grpcport = flag.String("grpcport", ":9902", "grpc port")
var svcname = flag.String("name", "extproc", "service name for logging")
var bodyDelay = flag.Duration("body-delay", 0, "delay for body chunk responses (e.g., 20ms)")
var hdrDelay = flag.Duration("hdr-delay", 0, "delay for response header responses (e.g., 50ms)")

func (s *server) Process(srv ext_proc.ExternalProcessor_ProcessServer) error {
	log.Printf("[%s] Got stream", s.name)
	ctx := srv.Context()
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}

		req, err := srv.Recv()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return status.Errorf(codes.Unknown, "cannot receive stream request: %v", err)
		}

		var resp *ext_proc.ProcessingResponse
		switch v := req.Request.(type) {
		case *ext_proc.ProcessingRequest_ResponseHeaders:
			if s.hdrDelay > 0 {
				time.Sleep(s.hdrDelay)
			}
			resp = &ext_proc.ProcessingResponse{
				Response: &ext_proc.ProcessingResponse_ResponseHeaders{
					ResponseHeaders: &ext_proc.HeadersResponse{},
				},
			}
			log.Printf("[%s] response headers", s.name)
		case *ext_proc.ProcessingRequest_ResponseBody:
			b := v.ResponseBody
			// Delay body responses to simulate real-world ext_proc processing time.
			// This creates the race window for the EoS bug (envoyproxy/envoy#41654):
			// the header-only filter resumes via commonContinue() with stale
			// observedEndStream()=true while this filter is still processing body.
			if s.bodyDelay > 0 {
				time.Sleep(s.bodyDelay)
			}
			resp = &ext_proc.ProcessingResponse{
				Response: &ext_proc.ProcessingResponse_ResponseBody{
					ResponseBody: &ext_proc.BodyResponse{
						Response: &ext_proc.CommonResponse{
							Status: ext_proc.CommonResponse_CONTINUE,
							BodyMutation: &ext_proc.BodyMutation{
								Mutation: &ext_proc.BodyMutation_StreamedResponse{
									StreamedResponse: &ext_proc.StreamedBodyResponse{
										Body:        b.GetBody(),
										EndOfStream: b.GetEndOfStream(),
									},
								},
							},
						},
					},
				},
			}
			log.Printf("[%s] response body chunk len=%d eos=%v", s.name, len(b.GetBody()), b.GetEndOfStream())
		case *ext_proc.ProcessingRequest_RequestHeaders:
			resp = &ext_proc.ProcessingResponse{
				Response: &ext_proc.ProcessingResponse_RequestHeaders{
					RequestHeaders: &ext_proc.HeadersResponse{},
				},
			}
			log.Printf("[%s] request headers", s.name)
		default:
			log.Printf("[%s] unknown request type", s.name)
			resp = &ext_proc.ProcessingResponse{
				Response: &ext_proc.ProcessingResponse_RequestHeaders{
					RequestHeaders: &ext_proc.HeadersResponse{},
				},
			}
		}

		if err := srv.Send(resp); err != nil {
			log.Printf("[%s] send error %v", s.name, err)
		}
	}
}

func main() {
	flag.Parse()
	lis, err := net.Listen("tcp", *grpcport)
	if err != nil {
		log.Fatalf("listen: %v", err)
	}
	s := grpc.NewServer(grpc.MaxRecvMsgSize(100*1024*1024), grpc.MaxSendMsgSize(100*1024*1024))
	ext_proc.RegisterExternalProcessorServer(s, &server{name: *svcname, bodyDelay: *bodyDelay, hdrDelay: *hdrDelay})
	go func() {
		ch := make(chan os.Signal, 1)
		signal.Notify(ch, syscall.SIGINT, syscall.SIGTERM)
		<-ch
		s.GracefulStop()
	}()
	log.Printf("[%s] listening on %s (body-delay=%v hdr-delay=%v)", *svcname, *grpcport, *bodyDelay, *hdrDelay)
	if err := s.Serve(lis); err != nil {
		log.Fatal(err)
	}
}
