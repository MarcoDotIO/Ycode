// Gauge's in-process sampler for Linux processes (specs/ide/profiler.md §3.2):
// a shared library loaded with LD_PRELOAD when perf_event_open is not allowed.
// Original Ycode code. The library has no API; it starts from its constructor
// when YCODE_GAUGE_SAMPLES names the output file.
#ifndef CYCODEGAUGEAGENT_H
#define CYCODEGAUGEAGENT_H
/// The record magic ("YGA1", little-endian).
#define YCODE_GAUGE_AGENT_MAGIC 0x31414759u
int ycode_gauge_agent_version(void);
#endif
