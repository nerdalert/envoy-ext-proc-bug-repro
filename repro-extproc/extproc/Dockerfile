FROM golang:1.24 AS build
WORKDIR /src
COPY go.mod ./
COPY main.go ./
RUN go mod tidy
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o /out/extproc .

FROM gcr.io/distroless/static:nonroot
COPY --from=build /out/extproc /extproc
ENTRYPOINT ["/extproc"]
