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


    public sealed class AlignmentPiece
    {
        public double VideoStart { get; set; }
        public double VideoEnd { get; set; }
        public double OffsetSeconds { get; set; }
        public double TimeScale { get; set; }
        public double Confidence { get; set; }
    }

    public sealed class SegmentedMatchResult
    {
        public AlignmentPiece[] Pieces { get; set; }
        public int EventCount { get; set; }
        public int CorrectedDiscontinuities { get; set; }
        public double Confidence { get; set; }
    }

    internal sealed class SyncInterval
    {
        public double Start;
        public double End;
    }

    internal sealed class SyncRegion
    {
        public double Start;
        public double End;
        public MatchResult Match;
        public double Offset;
        public double Confidence;
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


        public static SegmentedMatchResult FindSegmented(float[] video, float[] external, int sampleRate,
            double[] eventStarts, double[] eventEnds, double videoDuration)
        {
            if (eventStarts == null || eventEnds == null || eventStarts.Length != eventEnds.Length)
                throw new ArgumentException("Reconnect event arrays are invalid.");
            if (videoDuration <= 0 || sampleRate <= 0)
                throw new ArgumentOutOfRangeException("videoDuration");
            List<SyncInterval> events = new List<SyncInterval>();
            double availableVideo = video.Length / (double)sampleRate;
            for (int i = 0; i < eventStarts.Length; i++)
            {
                double start = Math.Max(0.0, eventStarts[i]);
                double end = Math.Min(videoDuration, eventEnds[i]);
                if (double.IsNaN(start) || double.IsNaN(end) || end - start < 0.9) continue;
                if (start < 1.0 || end >= availableVideo - 1.0) continue;
                events.Add(new SyncInterval { Start = start, End = end });
            }
            events.Sort((a, b) => a.Start.CompareTo(b.Start));
            List<SyncInterval> merged = new List<SyncInterval>();
            foreach (SyncInterval interval in events)
            {
                if (merged.Count > 0 && interval.Start - merged[merged.Count - 1].End < 5.0)
                {
                    merged[merged.Count - 1].End = Math.Max(merged[merged.Count - 1].End, interval.End);
                }
                else
                {
                    merged.Add(new SyncInterval { Start = interval.Start, End = interval.End });
                }
            }
            if (merged.Count == 0)
            {
                MatchResult regular = Find(video, external, sampleRate);
                return new SegmentedMatchResult
                {
                    EventCount = 0, CorrectedDiscontinuities = 0, Confidence = regular.Confidence,
                    Pieces = new AlignmentPiece[] { new AlignmentPiece {
                        VideoStart = 0, VideoEnd = videoDuration, OffsetSeconds = regular.OffsetSeconds,
                        TimeScale = regular.TimeScale, Confidence = regular.Confidence } }
                };
            }

            List<SyncRegion> regions = new List<SyncRegion>();
            double regionStart = 0;
            for (int index = 0; index <= merged.Count; index++)
            {
                double regionEnd = index == merged.Count ? Math.Min(videoDuration, availableVideo) : merged[index].Start;
                SyncRegion region = new SyncRegion { Start = regionStart, End = regionEnd };
                int first = Math.Max(0, (int)Math.Ceiling(regionStart * sampleRate));
                int last = Math.Min(video.Length, (int)Math.Floor(regionEnd * sampleRate));
                if (last - first >= 5 * sampleRate)
                {
                    float[] regionAudio = new float[last - first];
                    Array.Copy(video, first, regionAudio, 0, regionAudio.Length);
                    try
                    {
                        MatchResult match = Find(regionAudio, external, sampleRate);
                        if (match.MatchedAnchors >= 2 && match.Confidence >= 0.65 ||
                            match.MatchedAnchors == 1 && match.Confidence >= 0.95)
                        {
                            region.Match = match;
                            region.Offset = first / (double)sampleRate + match.OffsetSeconds;
                            region.Confidence = match.Confidence;
                        }
                    }
                    catch (InvalidOperationException) { }
                }
                regions.Add(region);
                if (index < merged.Count) regionStart = merged[index].End;
            }

            bool[] cuts = new bool[merged.Count];
            int corrections = 0;
            for (int index = 0; index < merged.Count; index++)
            {
                SyncRegion before = regions[index], after = regions[index + 1];
                if (before.Match == null || after.Match == null)
                    throw new InvalidOperationException(
                        "Audio matching failed around a suspected camera reconnect. Cannot guess the missing segment.");
                double externalBefore = (merged[index].Start - before.Offset) / before.Match.TimeScale;
                double externalAfter = (merged[index].End - after.Offset) / after.Match.TimeScale;
                double elapsed = externalAfter - externalBefore;
                if (elapsed < -0.20)
                    throw new InvalidOperationException("Matched audio overlaps at a reconnect event. Check the reference recordings.");
                double videoElapsed = merged[index].End - merged[index].Start;
                double missing = videoElapsed - elapsed * (before.Match.TimeScale + after.Match.TimeScale) / 2.0;
                if (Math.Abs(missing) >= Math.Max(0.65, videoElapsed * 0.04))
                {
                    cuts[index] = true;
                    corrections++;
                }
            }

            if (corrections == 0)
            {
                try
                {
                    MatchResult regular = Find(video, external, sampleRate);
                    return new SegmentedMatchResult
                    {
                        EventCount = merged.Count, CorrectedDiscontinuities = 0, Confidence = regular.Confidence,
                        Pieces = new AlignmentPiece[] { new AlignmentPiece {
                            VideoStart = 0, VideoEnd = videoDuration,
                            OffsetSeconds = regular.OffsetSeconds, TimeScale = regular.TimeScale,
                            Confidence = regular.Confidence } }
                    };
                }
                catch (InvalidOperationException) { }
            }

            List<AlignmentPiece> pieces = new List<AlignmentPiece>();
            int groupFrom = 0;
            double minimumConfidence = 1.0;
            for (int index = 0; index <= merged.Count; index++)
            {
                if (index < merged.Count && !cuts[index]) continue;
                int groupTo = index;
                SyncRegion representative = null;
                for (int regionIndex = groupFrom; regionIndex <= groupTo; regionIndex++)
                {
                    SyncRegion candidate = regions[regionIndex];
                    if (candidate.Match == null) continue;
                    if (representative == null ||
                        candidate.Match.MatchedAnchors > representative.Match.MatchedAnchors ||
                        candidate.Match.MatchedAnchors == representative.Match.MatchedAnchors &&
                        candidate.Confidence > representative.Confidence)
                        representative = candidate;
                }
                double outputStart = groupFrom == 0 ? 0.0 : merged[groupFrom - 1].End;
                double outputEnd = index == merged.Count ? videoDuration : merged[index].Start;
                if (representative == null)
                    throw new InvalidOperationException(
                        "Audio around the reconnect has no reliable matching samples. Alignment was not fabricated.");
                if (outputEnd > outputStart)
                {
                    foreach (SyncRegion other in regions)
                    {
                        if (other.Match == null || other.Start < outputStart || other.End > outputEnd) continue;
                        double middle = (other.Start + other.End) / 2.0;
                        double extAtMiddle = (middle - other.Offset) / other.Match.TimeScale;
                        double predicted = representative.Offset + representative.Match.TimeScale * extAtMiddle;
                        if (Math.Abs(predicted - middle) > Math.Max(0.55, (outputEnd - outputStart) * 0.003))
                            throw new InvalidOperationException(
                                "Audio alignment is inconsistent within a continuous segment.");
                    }
                    minimumConfidence = Math.Min(minimumConfidence, representative.Confidence);
                    pieces.Add(new AlignmentPiece {
                        VideoStart = outputStart, VideoEnd = outputEnd,
                        OffsetSeconds = representative.Offset,
                        TimeScale = representative.Match.TimeScale,
                        Confidence = representative.Confidence
                    });
                }
                groupFrom = index + 1;
            }
            if (pieces.Count == 0)
                throw new InvalidOperationException("There are no reliable audio synchronization segments.");
            return new SegmentedMatchResult {
                EventCount = merged.Count, CorrectedDiscontinuities = corrections,
                Confidence = minimumConfidence, Pieces = pieces.ToArray()
            };
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
