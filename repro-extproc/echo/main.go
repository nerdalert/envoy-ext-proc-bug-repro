package main

import (
	"io"
	"log"
	"net/http"
)

func main() {
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		_ = r.Body.Close()
		w.Header().Set("Content-Type", "application/octet-stream")
		w.WriteHeader(http.StatusOK)
		// Send entire response at once. This ensures Envoy's observedEndStream()
		// is set to true quickly, which is needed to trigger the EoS interleaving
		// bug when two ext_proc filters process the same response.
		_, _ = w.Write(b)
	})
	log.Fatal(http.ListenAndServe(":8080", nil))
}
