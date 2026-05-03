import os from "node:os";
import { readFile } from "node:fs/promises";
import { setTimeout as delay } from "node:timers/promises";

type CpuSample = {
  idle: number;
  total: number;
};

export async function readSystemStats() {
  const [cpuPercent, memory] = await Promise.all([
    sampleCpuPercent(),
    Promise.resolve(memoryStats())
  ]);
  return {
    cpu_percent: cpuPercent,
    memory,
    load_average: os.loadavg(),
    uptime_seconds: Math.floor(os.uptime()),
    platform: os.platform(),
    arch: os.arch(),
    hostname: os.hostname(),
    cpu_count: os.cpus().length
  };
}

async function sampleCpuPercent(): Promise<number | null> {
  const first = await readProcStat();
  if (!first) return null;
  await delay(120);
  const second = await readProcStat();
  if (!second) return null;

  const idleDelta = second.idle - first.idle;
  const totalDelta = second.total - first.total;
  if (totalDelta <= 0) return null;
  const busy = 1 - idleDelta / totalDelta;
  return Math.max(0, Math.min(100, busy * 100));
}

async function readProcStat(): Promise<CpuSample | undefined> {
  try {
    const content = await readFile("/proc/stat", "utf8");
    const line = content.split("\n")[0];
    const parts = line.trim().split(/\s+/).slice(1).map(Number);
    if (parts.length < 4 || parts.some((value) => Number.isNaN(value))) return undefined;
    const idle = parts[3] + (parts[4] ?? 0);
    const total = parts.reduce((sum, value) => sum + value, 0);
    return { idle, total };
  } catch {
    return undefined;
  }
}

function memoryStats() {
  const total = os.totalmem();
  const free = os.freemem();
  const used = Math.max(0, total - free);
  return {
    total_bytes: total,
    free_bytes: free,
    used_bytes: used,
    used_percent: total > 0 ? used / total * 100 : null
  };
}
