using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Threading;

namespace ReEncodeUtility
{
    public sealed class FFmpegUsageMonitor : IDisposable
    {
        private const uint MoreData = 0x800007D2;
        private const uint FormatDouble = 0x00000200;
        private const uint AllProcessorGroups = 0xffff;

        [StructLayout(LayoutKind.Sequential)]
        private struct CounterValue
        {
            public uint Status;
            public double Value;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct CounterItem
        {
            public IntPtr Name;
            public CounterValue Value;
        }

        [DllImport("pdh.dll", CharSet = CharSet.Unicode, EntryPoint = "PdhOpenQueryW")]
        private static extern uint PdhOpenQuery(string dataSource, IntPtr userData, out IntPtr query);

        [DllImport("pdh.dll", CharSet = CharSet.Unicode, EntryPoint = "PdhAddEnglishCounterW")]
        private static extern uint PdhAddEnglishCounter(IntPtr query, string path, IntPtr userData, out IntPtr counter);

        [DllImport("pdh.dll")]
        private static extern uint PdhCollectQueryData(IntPtr query);

        [DllImport("pdh.dll", CharSet = CharSet.Unicode, EntryPoint = "PdhGetFormattedCounterArrayW")]
        private static extern uint PdhGetFormattedCounterArray(IntPtr counter, uint format, ref uint bufferSize, out uint itemCount, IntPtr buffer);

        [DllImport("pdh.dll")]
        private static extern uint PdhCloseQuery(IntPtr query);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetProcessTimes(IntPtr processHandle, out long creation, out long exit, out long kernel, out long user);

        [DllImport("kernel32.dll")]
        private static extern uint GetActiveProcessorCount(uint groupNumber);

        private sealed class EngineStatistics
        {
            public int Count;
            public double Sum;
            public double Maximum;

            public void Add(double value)
            {
                Count++;
                Sum += value;
                Maximum = Math.Max(Maximum, value);
            }
        }

        private readonly IntPtr processHandle;
        private readonly int processId;
        private readonly int logicalProcessors;
        private readonly int intervalMilliseconds;
        private readonly string instancePrefix;
        private readonly ManualResetEvent stop = new ManualResetEvent(false);
        private readonly Thread worker;
        private readonly SortedDictionary<string, EngineStatistics> engines =
            new SortedDictionary<string, EngineStatistics>(StringComparer.OrdinalIgnoreCase);
        private bool disposed;
        private bool completed;
        private long previousCpuTime;
        private long previousWallTime;
        private double cpuMaximum;
        private int cpuSamples;
        private int gpuSamples;
        private string gpuError;

        public FFmpegUsageMonitor(IntPtr processHandle, int processId, int intervalMilliseconds)
        {
            if (processHandle == IntPtr.Zero) throw new ArgumentException("Process handle is invalid.");
            if (intervalMilliseconds < 100) throw new ArgumentOutOfRangeException("intervalMilliseconds");
            this.processHandle = processHandle;
            this.processId = processId;
            this.intervalMilliseconds = intervalMilliseconds;
            this.instancePrefix = "pid_" + processId.ToString(CultureInfo.InvariantCulture) + "_";
            uint count = GetActiveProcessorCount(AllProcessorGroups);
            this.logicalProcessors = count > 0 ? (int)count : Math.Max(1, Environment.ProcessorCount);
            worker = new Thread(SampleLoop);
            worker.IsBackground = true;
            worker.Name = "FFmpeg usage monitor";
            worker.Start();
        }

        private bool ReadCpu(out long creation, out long exit, out long cpu)
        {
            long kernel, user;
            bool ok = GetProcessTimes(processHandle, out creation, out exit, out kernel, out user);
            cpu = ok ? kernel + user : 0;
            return ok;
        }

        private void SampleCpu()
        {
            long creation, exit, cpu;
            if (!ReadCpu(out creation, out exit, out cpu)) return;
            long wall = exit > 0 ? exit : DateTime.UtcNow.ToFileTimeUtc();
            long start = previousWallTime > 0 ? previousWallTime : creation;
            long deltaWall = wall - start;
            long deltaCpu = cpu - previousCpuTime;
            if (deltaWall > 0 && deltaCpu >= 0)
            {
                double usage = 100.0 * deltaCpu / deltaWall / logicalProcessors;
                cpuMaximum = Math.Max(cpuMaximum, Math.Min(100.0, usage));
                cpuSamples++;
            }
            previousWallTime = wall;
            previousCpuTime = cpu;
        }

        private void SampleGpu(IntPtr counter, ref IntPtr buffer, ref uint capacity)
        {
            uint count = 0;
            uint size = capacity;
            uint status = PdhGetFormattedCounterArray(counter, FormatDouble, ref size, out count, buffer);

            for (int attempt = 0; status == MoreData && size > 0 && attempt < 3; attempt++)
            {
                if (buffer != IntPtr.Zero) Marshal.FreeHGlobal(buffer);
                buffer = IntPtr.Zero;
                capacity = size;
                buffer = Marshal.AllocHGlobal(checked((int)capacity));
                size = capacity;
                status = PdhGetFormattedCounterArray(counter, FormatDouble, ref size, out count, buffer);
            }

            if (status != 0) return;
            gpuSamples++;
            int itemSize = Marshal.SizeOf(typeof(CounterItem));
            for (uint i = 0; i < count; i++)
            {
                IntPtr address = IntPtr.Add(buffer, checked((int)i * itemSize));
                CounterItem item = (CounterItem)Marshal.PtrToStructure(address, typeof(CounterItem));
                if (item.Value.Status != 0 && item.Value.Status != 1) continue;
                string name = Marshal.PtrToStringUni(item.Name);
                if (String.IsNullOrEmpty(name) || !name.StartsWith(instancePrefix, StringComparison.OrdinalIgnoreCase)) continue;
                double value = item.Value.Value;
                if (Double.IsNaN(value) || Double.IsInfinity(value) || value < 0) continue;
                EngineStatistics stats;
                string engine = name.Substring(instancePrefix.Length);
                if (!engines.TryGetValue(engine, out stats))
                {
                    stats = new EngineStatistics();
                    engines.Add(engine, stats);
                }
                stats.Add(value);
            }
        }

        private void SampleLoop()
        {
            IntPtr query = IntPtr.Zero;
            IntPtr counter = IntPtr.Zero;
            IntPtr buffer = IntPtr.Zero;
            uint capacity = 0;
            try
            {
                try
                {
                    uint status = PdhOpenQuery(null, IntPtr.Zero, out query);
                    if (status == 0)
                        status = PdhAddEnglishCounter(query, @"\GPU Engine(*)\Utilization Percentage", IntPtr.Zero, out counter);
                    if (status != 0)
                    {
                        gpuError = String.Format(CultureInfo.InvariantCulture, "PDH initialization 0x{0:X8}", status);
                        counter = IntPtr.Zero;
                    }
                    if (counter != IntPtr.Zero) PdhCollectQueryData(query);
                }
                catch (Exception ex)
                {
                    gpuError = ex.Message;
                    counter = IntPtr.Zero;
                }

                while (!stop.WaitOne(intervalMilliseconds))
                {
                    SampleCpu();
                    long creation, exit, cpu;
                    if (!ReadCpu(out creation, out exit, out cpu) || exit > 0) break;
                    if (counter != IntPtr.Zero)
                    {
                        try
                        {
                            if (PdhCollectQueryData(query) == 0)
                                SampleGpu(counter, ref buffer, ref capacity);
                        }
                        catch (Exception ex)
                        {
                            gpuError = ex.Message;
                            counter = IntPtr.Zero;
                        }
                    }
                }
            }
            finally
            {
                if (buffer != IntPtr.Zero) Marshal.FreeHGlobal(buffer);
                if (query != IntPtr.Zero) PdhCloseQuery(query);
            }
        }

        public string[] Finish()
        {
            stop.Set();
            if (!completed)
            {
                if (!worker.Join(3000))
                    return new string[] { "PID: " + processId, "Usage monitor: N/A (sampling did not stop in time)" };
                completed = true;
                SampleCpu();
            }

            List<string> lines = new List<string>();
            lines.Add(String.Format(CultureInfo.InvariantCulture, "PID: {0} / interval: {1} ms", processId, intervalMilliseconds));
            long creation, exit, cpu;
            if (ReadCpu(out creation, out exit, out cpu))
            {
                long wall = exit > 0 ? exit : DateTime.UtcNow.ToFileTimeUtc();
                double duration = (wall - creation) / 10000000.0;
                if (duration > 0)
                {
                    double cpuSeconds = cpu / 10000000.0;
                    double average = 100.0 * cpuSeconds / duration / logicalProcessors;
                    lines.Add(String.Format(CultureInfo.InvariantCulture,
                        "CPU (all {0} logical processors): average {1:F2}% / peak {2:F2}% / CPU time {3:F3} s / samples {4}",
                        logicalProcessors, Math.Min(100.0, average), cpuMaximum, cpuSeconds, cpuSamples));
                }
                else lines.Add("CPU: N/A");
            }
            else lines.Add("CPU: N/A (GetProcessTimes failed)");

            lines.Add(String.Format(CultureInfo.InvariantCulture, "GPU Engine (PID only): {0} valid counter reads", gpuSamples));
            if (engines.Count == 0)
                lines.Add("GPU: N/A (no valid engine instances for this PID)");
            foreach (KeyValuePair<string, EngineStatistics> item in engines)
            {
                EngineStatistics stats = item.Value;
                lines.Add(String.Format(CultureInfo.InvariantCulture,
                    "  {0}: average {1:F2}% / peak {2:F2}% / samples {3}",
                    item.Key, stats.Sum / stats.Count, stats.Maximum, stats.Count));
            }
            if (!String.IsNullOrEmpty(gpuError)) lines.Add("GPU monitor: " + gpuError);
            return lines.ToArray();
        }

        public void Dispose()
        {
            if (disposed) return;
            disposed = true;
            stop.Set();
            if (completed || worker.Join(3000)) stop.Dispose();
        }
    }
}
