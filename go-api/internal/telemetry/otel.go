package telemetry

import (
	"context"
	"fmt"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.20.0"

	"github.com/NFRohan/PixTools/go-api/internal/config"
)

// InitTracer configures an OpenTelemetry exporter and trace provider
func InitTracer(ctx context.Context, cfg *config.Config) (*sdktrace.TracerProvider, error) {
	if !cfg.ObservabilityEnabled {
		return nil, nil // Tracing disabled
	}

	res, err := resource.New(ctx,
		resource.WithAttributes(
			semconv.ServiceName(cfg.OtelServiceName),
			semconv.ServiceVersion("1.0.0"),
		),
	)
	if err != nil {
		return nil, fmt.Errorf("failed to create resource: %w", err)
	}

	// Initialize the exporter.
	// We use Insecure because Grafana Alloy runs as a local DaemonSet inside the Kubernetes cluster on :4318
	exporter, err := otlptracehttp.New(ctx,
		otlptracehttp.WithEndpointURL(fmt.Sprintf("%s/v1/traces", cfg.OtelEndpoint)),
		otlptracehttp.WithInsecure(),
		otlptracehttp.WithTimeout(2*time.Second),
	)
	if err != nil {
		return nil, fmt.Errorf("failed to create trace exporter: %w", err)
	}

	// Register the trace provider
	bsp := sdktrace.NewBatchSpanProcessor(exporter)
	tracerProvider := sdktrace.NewTracerProvider(
		sdktrace.WithSampler(sdktrace.AlwaysSample()),
		sdktrace.WithResource(res),
		sdktrace.WithSpanProcessor(bsp),
	)
	otel.SetTracerProvider(tracerProvider)

	// Set global propagator to tracecontext (the default).
	otel.SetTextMapPropagator(propagation.TraceContext{})

	return tracerProvider, nil
}
