package main

import (
	"context"
	"encoding/json"
	"log"
	"math"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
)

var (
	docsTotal = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "docservice_docs_total",
		Help: "Documentos por estado",
	}, []string{"status"})

	docsNonTerminal = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "docservice_docs_non_terminal",
		Help: "Documentos en estados no terminales",
	})

	docsCompleted = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "docservice_docs_completed_total",
		Help: "Documentos COMPLETED",
	})

	docsFailed = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "docservice_docs_failed_total",
		Help: "Documentos FAILED",
	})

	docsRejected = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "docservice_docs_rejected_total",
		Help: "Documentos REJECTED",
	})

	docsExpired = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "docservice_docs_upload_expired_total",
		Help: "Documentos UPLOAD_EXPIRED",
	})

	docsRecovered = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "docservice_docs_recovered_total",
		Help: "Documentos con intervención de reconciliador",
	})

	pipelineP50 = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "docservice_pipeline_p50_seconds",
		Help: "p50 POST->terminal (segundos)",
	})

	pipelineP95 = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "docservice_pipeline_p95_seconds",
		Help: "p95 POST->terminal (segundos)",
	})

	pipelineP99 = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "docservice_pipeline_p99_seconds",
		Help: "p99 POST->terminal (segundos)",
	})

	pipelineTerminalRate = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "docservice_pipeline_terminal_rate",
		Help: "Tasa de documentos terminales (0-1)",
	})

	pipelineWithin10m = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "docservice_pipeline_terminal_within_10m_rate",
		Help: "Tasa de documentos terminales en < 10 minutos (0-1)",
	})

	scrapeDuration = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "docservice_slo_exporter_scrape_duration_seconds",
		Help: "Duración del scrape",
	})

	scrapeErrors = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "docservice_slo_exporter_scrape_errors",
		Help: "Errores en último scrape (0/1)",
	})
)

func env(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

func envInt(k string, d int) int {
	if v := os.Getenv(k); v != "" {
		if i, err := strconv.Atoi(v); err == nil {
			return i
		}
	}
	return d
}

type collector struct {
	client *mongo.Client
	db     string
	window time.Duration
	mu     sync.RWMutex
}

func newCollector() (*collector, error) {
	uri := env("MONGO_URI", "mongodb://localhost:27017")
	db := env("MONGO_DB", "documents")
	windowH := envInt("SLO_WINDOW_HOURS", 24)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	client, err := mongo.Connect(ctx, options.Client().ApplyURI(uri))
	if err != nil {
		return nil, err
	}
	return &collector{client: client, db: db, window: time.Duration(windowH) * time.Hour}, nil
}

func (c *collector) scrape() {
	start := time.Now()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	coll := c.client.Database(c.db).Collection("documents")
	since := time.Now().UTC().Add(-c.window)

	cursor, err := coll.Find(ctx, bson.M{"created_at": bson.M{"$gte": since}})
	if err != nil {
		log.Printf("find error: %v", err)
		scrapeErrors.Set(1)
		scrapeDuration.Set(time.Since(start).Seconds())
		return
	}
	defer cursor.Close(ctx)

	type doc struct {
		ID        string    `bson:"_id"`
		Status    string    `bson:"status"`
		CreatedAt time.Time `bson:"created_at"`
		History   []struct {
			Status string    `bson:"status"`
			Actor  string    `bson:"actor"`
			At     time.Time `bson:"at"`
		} `bson:"history"`
	}
	var docs []doc
	if err := cursor.All(ctx, &docs); err != nil {
		log.Printf("decode error: %v", err)
		scrapeErrors.Set(1)
		scrapeDuration.Set(time.Since(start).Seconds())
		return
	}

	terminal := map[string]bool{"COMPLETED": true, "FAILED": true, "REJECTED": true, "UPLOAD_EXPIRED": true}
	nonTerm := 0
	byStatus := map[string]int{}
	var durations []float64
	completed, failed, rejected, expired, recovered := 0, 0, 0, 0, 0

	for _, d := range docs {
		byStatus[d.Status]++
		if !terminal[d.Status] {
			nonTerm++
			continue
		}
		if d.Status == "COMPLETED" {
			completed++
		}
		if d.Status == "FAILED" {
			failed++
		}
		if d.Status == "REJECTED" {
			rejected++
		}
		if d.Status == "UPLOAD_EXPIRED" {
			expired++
		}
		// recovered
		rec := false
		for _, h := range d.History {
			if h.Actor == "reconciler" {
				rec = true
				break
			}
		}
		if rec {
			recovered++
		}
		// duration
		if d.Status == "COMPLETED" && len(d.History) > 0 {
			end := d.History[len(d.History)-1].At
			if end.After(d.CreatedAt) {
				durations = append(durations, end.Sub(d.CreatedAt).Seconds())
			}
		} else if len(d.History) > 0 {
			end := d.History[len(d.History)-1].At
			if end.After(d.CreatedAt) {
				durations = append(durations, end.Sub(d.CreatedAt).Seconds())
			}
		}
	}

	docsNonTerminal.Set(float64(nonTerm))
	docsCompleted.Set(float64(completed))
	docsFailed.Set(float64(failed))
	docsRejected.Set(float64(rejected))
	docsExpired.Set(float64(expired))
	docsRecovered.Set(float64(recovered))

	for s, c := range byStatus {
		docsTotal.WithLabelValues(s).Set(float64(c))
	}

	total := len(docs)
	if total > 0 {
		termCount := total - nonTerm
		pipelineTerminalRate.Set(float64(termCount) / float64(total))
		if len(durations) > 0 {
			sort.Float64s(durations)
			p := func(arr []float64, q float64) float64 {
				if len(arr) == 0 {
					return 0
				}
				idx := int(math.Ceil(q*float64(len(arr)))) - 1
				if idx < 0 {
					idx = 0
				}
				if idx >= len(arr) {
					idx = len(arr) - 1
				}
				return arr[idx]
			}
			pipelineP50.Set(p(durations, 0.5))
			pipelineP95.Set(p(durations, 0.95))
			pipelineP99.Set(p(durations, 0.99))
			within := 0
			for _, d := range durations {
				if d <= 600 {
					within++
				}
			}
			pipelineWithin10m.Set(float64(within) / float64(len(durations)))
		}
	} else {
		pipelineTerminalRate.Set(0)
		pipelineWithin10m.Set(0)
		pipelineP50.Set(0)
		pipelineP95.Set(0)
		pipelineP99.Set(0)
	}

	scrapeErrors.Set(0)
	scrapeDuration.Set(time.Since(start).Seconds())
}

func main() {
	prometheus.MustRegister(docsTotal, docsNonTerminal, docsCompleted, docsFailed, docsRejected, docsExpired, docsRecovered, pipelineP50, pipelineP95, pipelineP99, pipelineTerminalRate, pipelineWithin10m, scrapeDuration, scrapeErrors)
	c, err := newCollector()
	if err != nil {
		log.Fatal(err)
	}
	go func() {
		for {
			c.scrape()
			time.Sleep(15 * time.Second)
		}
	}()
	http.Handle("/metrics", promhttp.Handler())
	addr := env("LISTEN_ADDR", ":9100")
	log.Printf("slo-exporter listening on %s", addr)
	log.Fatal(http.ListenAndServe(addr, nil))
}
