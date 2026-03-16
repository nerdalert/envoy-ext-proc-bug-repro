FROM golang:1.24 AS build
WORKDIR /src
COPY go.mod ./
COPY main.go ./
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o /out/echo .

FROM gcr.io/distroless/static:nonroot
COPY --from=build /out/echo /echo
ENTRYPOINT ["/echo"]
