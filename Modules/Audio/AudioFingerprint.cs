using System;
using System.Collections.Generic;
using System.IO;

namespace ReEncodeUtility.Audio
{
    public sealed class MatchResult
    {
        public double OffsetSeconds { get; set; }
        public double TimeScale { get; set; }
        public double Confidence { get; set; }
        public int MatchedAnchors { get; set; }
    }

    internal sealed class Candidate
    {
        public double VideoTime;
        public double ExternalTime;
        public double Score;
    }

    public static class FingerprintMatcher
    {
        public static float[] ReadSamples(string path)
        {
            byte[] bytes = File.ReadAllBytes(path);
            if (bytes.Length == 0 || bytes.Length % sizeof(float) != 0)
                throw new InvalidDataException("The audio fingerprint is empty or invalid.");
            float[] values = new float[bytes.Length / sizeof(float)];
            Buffer.BlockCopy(bytes, 0, values, 0, bytes.Length);
            return values;
        }

        private static double Correlate(float[] needle, float[] haystack, int start, int length,
            int position, double[] prefix, double[] prefixSquares, double[] centered, double variance)
        {
            double sum = prefix[position + length] - prefix[position];
            double energy = prefixSquares[position + length] - prefixSquares[position] - sum * sum / length;
            if (energy <= 1e-11 || variance <= 1e-11) return -1.0;
            double dot = 0.0;
            for (int j = 0; j < length; j++) dot += centered[j] * haystack[position + j];
            return dot / Math.Sqrt(variance * energy);
        }

        private static List<Candidate> FindCandidates(float[] shorter, float[] longer,
            bool shortIsVideo, int start, int length, int sampleRate)
        {
            double mean = 0.0;
            for (int i = 0; i < length; i++) mean += shorter[start + i];
            mean /= length;
            double[] centered = new double[length];
            double variance = 0.0;
            for (int i = 0; i < length; i++)
            {
                centered[i] = shorter[start + i] - mean;
                variance += centered[i] * centered[i];
            }
            if (variance <= 1e-11) return new List<Candidate>();

            double[] sums = new double[longer.Length + 1];
            double[] squares = new double[longer.Length + 1];
            for (int i = 0; i < longer.Length; i++)
            {
                sums[i + 1] = sums[i] + longer[i];
                squares[i + 1] = squares[i] + (double)longer[i] * longer[i];
            }

            List<Tuple<int, double>> peaks = new List<Tuple<int, double>>();
            int stride = Math.Max(1, sampleRate / 10);
            int max = longer.Length - length;
            for (int p = 0; p <= max; p += stride)
            {
                double score = Correlate(shorter, longer, start, length, p, sums, squares, centered, variance);
                if (score < 0.50) continue;
                bool replaced = false;
                for (int j = 0; j < peaks.Count; j++)
                {
                    if (Math.Abs(peaks[j].Item1 - p) < sampleRate)
                    {
                        if (score > peaks[j].Item2) peaks[j] = Tuple.Create(p, score);
                        replaced = true;
                        break;
                    }
                }
                if (!replaced) peaks.Add(Tuple.Create(p, score));
                peaks.Sort((a, b) => b.Item2.CompareTo(a.Item2));
                if (peaks.Count > 8) peaks.RemoveRange(8, peaks.Count - 8);
            }

            List<Candidate> result = new List<Candidate>();
            foreach (Tuple<int, double> peak in peaks)
            {
                int best = peak.Item1;
                double bestScore = peak.Item2;
                for (int p = Math.Max(0, peak.Item1 - stride); p <= Math.Min(max, peak.Item1 + stride); p++)
                {
                    double score = Correlate(shorter, longer, start, length, p, sums, squares, centered, variance);
                    if (score > bestScore) { bestScore = score; best = p; }
                }
                if (bestScore < 0.60) continue;
                Candidate c = new Candidate();
                c.VideoTime = (shortIsVideo ? start : best) / (double)sampleRate;
                c.ExternalTime = (shortIsVideo ? best : start) / (double)sampleRate;
                c.Score = bestScore;
                result.Add(c);
            }
            return result;
        }

        public static MatchResult FindRange(float[] video, float[] external, int sampleRate,
            double videoStartSeconds, double videoEndSeconds)
        {
            if (sampleRate <= 0) throw new ArgumentOutOfRangeException("sampleRate");
            int from = Math.Max(0, (int)Math.Round(videoStartSeconds * sampleRate));
            int to = Math.Min(video.Length, (int)Math.Round(videoEndSeconds * sampleRate));
            if (to - from < 2 * sampleRate)
                throw new InvalidOperationException("This segment is too short for waveform matching.");
            float[] segment = new float[to - from];
            Array.Copy(video, from, segment, 0, segment.Length);
            MatchResult result = Find(segment, external, sampleRate);
            result.OffsetSeconds += from / (double)sampleRate;
            return result;
        }

        public static MatchResult Find(float[] video, float[] external, int sampleRate)
        {
            if (sampleRate <= 0) throw new ArgumentOutOfRangeException("sampleRate");
            bool shortIsVideo = video.Length <= external.Length;
            float[] shorter = shortIsVideo ? video : external;
            float[] longer = shortIsVideo ? external : video;
            if (shorter.Length < 2 * sampleRate)
                throw new InvalidOperationException("At least two seconds of audio are required.");

            int width = Math.Min(8 * sampleRate, Math.Max(2 * sampleRate, shorter.Length / 5));
            int maxStart = shorter.Length - width;
            int[] positions = new int[] { maxStart / 10, maxStart / 2, maxStart * 9 / 10 };
            List<List<Candidate>> groups = new List<List<Candidate>>();
            int prev = -1;
            foreach (int start in positions)
            {
                if (prev >= 0 && Math.Abs(start - prev) < sampleRate) continue;
                prev = start;
                List<Candidate> found = FindCandidates(shorter, longer, shortIsVideo, start, width, sampleRate);
                if (found.Count > 0) groups.Add(found);
            }

            Candidate bestA = null, bestB = null;
            double bestPair = -1;
            for (int i = 0; i < groups.Count; i++)
                for (int j = i + 1; j < groups.Count; j++)
                    foreach (Candidate a in groups[i])
                        foreach (Candidate b in groups[j])
                        {
                            double deltaExternal = b.ExternalTime - a.ExternalTime;
                            double deltaVideo = b.VideoTime - a.VideoTime;
                            if (deltaExternal <= 0.5 || deltaVideo <= 0.5) continue;
                            if (Math.Abs(deltaVideo - deltaExternal) > Math.Max(0.06, 0.003 * deltaExternal)) continue;
                            double score = a.Score + b.Score + Math.Min(0.1, deltaExternal / 600.0);
                            if (score > bestPair)
                            {
                                bestPair = score;
                                bestA = a;
                                bestB = b;
                            }
                        }

            if (bestA != null)
            {
                List<Candidate> accepted = new List<Candidate> { bestA, bestB };
                double slope = (bestB.VideoTime - bestA.VideoTime) / (bestB.ExternalTime - bestA.ExternalTime);
                double offset = bestA.VideoTime - slope * bestA.ExternalTime;
                foreach (List<Candidate> group in groups)
                {
                    Candidate best = null;
                    foreach (Candidate c in group)
                    {
                        if (Math.Abs(c.VideoTime - (offset + slope * c.ExternalTime)) <= 0.2 &&
                            (best == null || c.Score > best.Score)) best = c;
                    }
                    if (best != null && !accepted.Contains(best)) accepted.Add(best);
                }
                // A very short baseline cannot distinguish clock drift from matching jitter.
                if (Math.Abs(bestB.ExternalTime - bestA.ExternalTime) < 30.0) slope = 1.0;
                if (accepted.Count >= 3 && Math.Abs(bestB.ExternalTime - bestA.ExternalTime) >= 30.0)
                {
                    double xsum = 0, ysum = 0, xx = 0, xy = 0;
                    foreach (Candidate c in accepted) { xsum += c.ExternalTime; ysum += c.VideoTime; }
                    double xm = xsum / accepted.Count, ym = ysum / accepted.Count;
                    foreach (Candidate c in accepted) { xx += (c.ExternalTime - xm) * (c.ExternalTime - xm); xy += (c.ExternalTime - xm) * (c.VideoTime - ym); }
                    if (xx > 0)
                    {
                        double fitted = xy / xx;
                        if (Math.Abs(fitted - 1.0) <= 0.003) slope = fitted;
                    }
                }
                offset = bestA.VideoTime - slope * bestA.ExternalTime;
                double confidence = 0.0;
                foreach (Candidate c in accepted) confidence += c.Score;
                confidence /= accepted.Count;
                return new MatchResult { OffsetSeconds = offset, TimeScale = slope,
                    Confidence = confidence, MatchedAnchors = accepted.Count };
            }

            // Only exceptionally strong, unambiguous matches may use one anchor.
            if (groups.Count > 0)
            {
                Candidate top = null, second = null;
                foreach (List<Candidate> g in groups)
                    foreach (Candidate c in g)
                    {
                        if (top == null || c.Score > top.Score) { second = top; top = c; }
                        else if (second == null || c.Score > second.Score) second = c;
                    }
                if (top != null && top.Score >= 0.93 &&
                    (second == null || top.Score - second.Score >= 0.12))
                    return new MatchResult { OffsetSeconds = top.VideoTime - top.ExternalTime,
                        TimeScale = 1.0, Confidence = top.Score, MatchedAnchors = 1 };
            }
            throw new InvalidOperationException("Waveform alignment is not reliable. Supply a manual offset.");
        }
    }
}
