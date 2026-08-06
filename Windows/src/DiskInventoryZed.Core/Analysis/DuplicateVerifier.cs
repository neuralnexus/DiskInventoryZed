using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using DiskInventoryZed.Core.Models;
using DiskInventoryZed.Core.Scanning;
using DiskInventoryZed.Core.Utilities;

namespace DiskInventoryZed.Core.Analysis;

public enum DuplicateVerificationPhase
{
    Sampling,
    Hashing
}

public sealed record DuplicateVerificationProgress(
    DuplicateVerificationPhase Phase,
    int CompletedFiles,
    int TotalFiles,
    string CurrentPath);

public sealed record VerifiedDuplicateGroup(
    string Digest,
    long FileSize,
    IReadOnlyList<FileNode> Files,
    long PotentialSavings)
{
    public VerifiedDuplicateGroup(string digest, long fileSize, IReadOnlyList<FileNode> files)
        : this(digest, fileSize, files, CalculatePotentialSavings(files))
    {
    }

    public string DisplayName => $"{Files.Count:N0} verified identical files";
    public string Summary => $"Up to {ByteSizeFormatter.Format(PotentialSavings)} reclaimable";

    private static long CalculatePotentialSavings(IReadOnlyList<FileNode> files)
    {
        if (files.Count < 2)
        {
            return 0;
        }

        var total = 0L;
        var minimum = long.MaxValue;
        foreach (var file in files)
        {
            total = checked(total + file.AllocatedSize);
            minimum = Math.Min(minimum, file.AllocatedSize);
        }
        return total - minimum;
    }
}

public sealed record DuplicateVerificationResult(
    IReadOnlyList<VerifiedDuplicateGroup> Groups,
    IReadOnlyList<string> UnreadablePaths,
    int TotalUnreadableFiles);

public static class DuplicateVerifier
{
    private const int SampleSize = 64 * 1024;
    private const int ReadBufferSize = 1024 * 1024;
    private const FileAttributes RecallOnDataAccess = (FileAttributes)0x00400000;
    internal const int MaximumNonTerminalProgressReportsPerPhase = 500;

    public static async Task<DuplicateVerificationResult> VerifyAsync(
        IReadOnlyList<DuplicateCandidate> candidates,
        IProgress<DuplicateVerificationProgress>? progress = null,
        CancellationToken cancellationToken = default)
    {
        try
        {
            return await VerifyCoreAsync(candidates, progress, cancellationToken).ConfigureAwait(false);
        }
        catch (InvalidOperationException) when (cancellationToken.IsCancellationRequested)
        {
            cancellationToken.ThrowIfCancellationRequested();
            throw;
        }
    }

    private static async Task<DuplicateVerificationResult> VerifyCoreAsync(
        IReadOnlyList<DuplicateCandidate> candidates,
        IProgress<DuplicateVerificationProgress>? progress,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var files = SortFiles(
            ObserveCancellation(candidates, cancellationToken)
                .SelectMany(candidate => ObserveCancellation(candidate.Files, cancellationToken))
                .Where(file => !file.IsHardLinkDuplicate)
                .DistinctBy(file => file.Id, StringComparer.Ordinal),
            cancellationToken);
        var unreadable = new List<string>();
        var unreadableFiles = new HashSet<string>(StringComparer.Ordinal);
        var samples = new Dictionary<string, List<FileNode>>(StringComparer.Ordinal);
        var progressReporter = new ProgressReporter(progress);

        if (files.Length > 0)
        {
            progressReporter.Report(DuplicateVerificationPhase.Sampling, 0, files.Length, files[0].FullPath, true);
        }
        for (var index = 0; index < files.Length; index++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var file = files[index];
            try
            {
                var digest = await SampleDigestAsync(file, cancellationToken).ConfigureAwait(false);
                AddToGroup(samples, $"{file.LogicalSize}|{digest}", file);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or CryptographicException)
            {
                RecordUnreadable(file.FullPath);
            }
            progressReporter.Report(
                DuplicateVerificationPhase.Sampling,
                index + 1,
                files.Length,
                file.FullPath,
                index + 1 == files.Length);
        }

        var filesToHash = SortFiles(
            ObserveCancellation(samples.Values, cancellationToken)
                .Where(group => group.Count > 1)
                .SelectMany(group => ObserveCancellation(group, cancellationToken)),
            cancellationToken);
        var fullHashes = new Dictionary<string, List<FileNode>>(StringComparer.Ordinal);
        if (filesToHash.Length > 0)
        {
            progressReporter.Report(
                DuplicateVerificationPhase.Hashing,
                0,
                filesToHash.Length,
                filesToHash[0].FullPath,
                true);
        }
        for (var index = 0; index < filesToHash.Length; index++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var file = filesToHash[index];
            try
            {
                var digest = await FullDigestAsync(file, cancellationToken).ConfigureAwait(false);
                AddToGroup(fullHashes, $"{file.LogicalSize}|{digest}", file);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or CryptographicException)
            {
                RecordUnreadable(file.FullPath);
            }
            progressReporter.Report(
                DuplicateVerificationPhase.Hashing,
                index + 1,
                filesToHash.Length,
                file.FullPath,
                index + 1 == filesToHash.Length);
        }

        var groups = new List<VerifiedDuplicateGroup>();
        foreach (var item in ObserveCancellation(fullHashes, cancellationToken))
        {
            if (item.Value.Count < 2)
            {
                continue;
            }
            var orderedFiles = SortFiles(item.Value, cancellationToken);
            var potentialSavings = CalculatePotentialSavings(orderedFiles, cancellationToken);
            groups.Add(new VerifiedDuplicateGroup(
                item.Key[(item.Key.IndexOf('|') + 1)..],
                item.Value[0].LogicalSize,
                orderedFiles,
                potentialSavings));
        }
        groups.Sort(new CancellationComparer<VerifiedDuplicateGroup>(
            Comparer<VerifiedDuplicateGroup>.Create(static (left, right) =>
            {
                var savingsOrder = right.PotentialSavings.CompareTo(left.PotentialSavings);
                return savingsOrder != 0
                    ? savingsOrder
                    : StringComparer.Ordinal.Compare(left.Digest, right.Digest);
            }),
            cancellationToken));
        var groupArray = new VerifiedDuplicateGroup[groups.Count];
        for (var index = 0; index < groups.Count; index++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            groupArray[index] = groups[index];
        }
        cancellationToken.ThrowIfCancellationRequested();
        return new DuplicateVerificationResult(groupArray, unreadable, unreadableFiles.Count);

        void RecordUnreadable(string path)
        {
            if (unreadableFiles.Add(path) && unreadable.Count < 100)
            {
                unreadable.Add(path);
            }
        }
    }

    private static async Task<string> SampleDigestAsync(FileNode node, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var before = Fingerprint.Read(node.FullPath);
        cancellationToken.ThrowIfCancellationRequested();
        if (before.Size != node.LogicalSize)
        {
            throw new IOException("The file changed after it was scanned.");
        }

        cancellationToken.ThrowIfCancellationRequested();
        await using var stream = OpenRead(node.FullPath);
        cancellationToken.ThrowIfCancellationRequested();
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        hash.AppendData(Encoding.UTF8.GetBytes(node.LogicalSize.ToString(System.Globalization.CultureInfo.InvariantCulture)));
        var buffer = new byte[SampleSize];
        var expectedCount = (int)Math.Min(SampleSize, node.LogicalSize);
        await stream.ReadExactlyAsync(buffer.AsMemory(0, expectedCount), cancellationToken);
        var count = expectedCount;
        hash.AppendData(buffer, 0, count);
        if (node.LogicalSize > SampleSize)
        {
            cancellationToken.ThrowIfCancellationRequested();
            stream.Seek(Math.Max(0, node.LogicalSize - SampleSize), SeekOrigin.Begin);
            await stream.ReadExactlyAsync(buffer, cancellationToken);
            count = buffer.Length;
            hash.AppendData(buffer, 0, count);
        }

        var digest = Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant();
        cancellationToken.ThrowIfCancellationRequested();
        var after = Fingerprint.Read(node.FullPath);
        cancellationToken.ThrowIfCancellationRequested();
        if (after != before)
        {
            throw new IOException("The file changed while it was being sampled.");
        }

        return digest;
    }

    private static async Task<string> FullDigestAsync(FileNode node, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var before = Fingerprint.Read(node.FullPath);
        cancellationToken.ThrowIfCancellationRequested();
        if (before.Size != node.LogicalSize)
        {
            throw new IOException("The file changed after it was scanned.");
        }

        cancellationToken.ThrowIfCancellationRequested();
        await using var stream = OpenRead(node.FullPath);
        cancellationToken.ThrowIfCancellationRequested();
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        var buffer = new byte[ReadBufferSize];
        while (true)
        {
            var count = await stream.ReadAsync(buffer, cancellationToken);
            if (count == 0)
            {
                break;
            }

            hash.AppendData(buffer, 0, count);
        }

        var digest = Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant();
        cancellationToken.ThrowIfCancellationRequested();
        var after = Fingerprint.Read(node.FullPath);
        cancellationToken.ThrowIfCancellationRequested();
        if (after != before)
        {
            throw new IOException("The file changed while it was being verified.");
        }

        return digest;
    }

    internal static FileStream OpenRead(string path)
    {
        if (OperatingSystem.IsWindows())
        {
            return WindowsFileMetadata.OpenLocallyAvailableRead(path, ReadBufferSize);
        }

        var attributes = File.GetAttributes(path);
        if (attributes.HasFlag(FileAttributes.Directory) ||
            attributes.HasFlag(FileAttributes.Offline) ||
            attributes.HasFlag(RecallOnDataAccess))
        {
            throw new IOException("Only locally available regular files can be verified.");
        }

        return new FileStream(
            path,
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read,
            ReadBufferSize,
            FileOptions.Asynchronous | FileOptions.SequentialScan);
    }

    private static void AddToGroup(Dictionary<string, List<FileNode>> groups, string key, FileNode node)
    {
        if (!groups.TryGetValue(key, out var group))
        {
            group = [];
            groups[key] = group;
        }

        group.Add(node);
    }

    private static FileNode[] SortFiles(IEnumerable<FileNode> source, CancellationToken cancellationToken)
    {
        var files = ObserveCancellation(source, cancellationToken).ToList();
        files.Sort(new CancellationComparer<FileNode>(
            Comparer<FileNode>.Create(static (left, right) =>
            {
                var pathOrder = StringComparer.OrdinalIgnoreCase.Compare(left.FullPath, right.FullPath);
                return pathOrder != 0
                    ? pathOrder
                    : StringComparer.Ordinal.Compare(left.FullPath, right.FullPath);
            }),
            cancellationToken));
        cancellationToken.ThrowIfCancellationRequested();
        return files.ToArray();
    }

    private static long CalculatePotentialSavings(
        IReadOnlyList<FileNode> files,
        CancellationToken cancellationToken)
    {
        if (files.Count < 2)
        {
            return 0;
        }

        var total = 0L;
        var minimum = long.MaxValue;
        for (var index = 0; index < files.Count; index++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var allocatedSize = files[index].AllocatedSize;
            total = checked(total + allocatedSize);
            minimum = Math.Min(minimum, allocatedSize);
        }
        return total - minimum;
    }

    private static IEnumerable<T> ObserveCancellation<T>(
        IEnumerable<T> source,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        using var enumerator = source.GetEnumerator();
        while (true)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (!enumerator.MoveNext())
            {
                yield break;
            }
            cancellationToken.ThrowIfCancellationRequested();
            yield return enumerator.Current;
        }
    }

    private sealed class CancellationComparer<T>(IComparer<T> inner, CancellationToken cancellationToken) : IComparer<T>
    {
        private int _comparisons;

        public int Compare(T? left, T? right)
        {
            if ((_comparisons++ & 255) == 0)
            {
                cancellationToken.ThrowIfCancellationRequested();
            }
            return inner.Compare(left!, right!);
        }
    }

    internal sealed class ProgressReporter
    {
        private static readonly TimeSpan MinimumInterval = TimeSpan.FromMilliseconds(125);
        private readonly IProgress<DuplicateVerificationProgress>? _progress;
        private readonly Func<long> _getTimestamp;
        private DuplicateVerificationPhase? _phase;
        private long _lastTimestamp;
        private int _reportsInPhase;

        public ProgressReporter(
            IProgress<DuplicateVerificationProgress>? progress,
            Func<long>? getTimestamp = null)
        {
            _progress = progress;
            _getTimestamp = getTimestamp ?? Stopwatch.GetTimestamp;
        }

        public void Report(
            DuplicateVerificationPhase phase,
            int completedFiles,
            int totalFiles,
            string currentPath,
            bool force)
        {
            if (_progress is null)
            {
                return;
            }

            var phaseChanged = _phase != phase;
            if (phaseChanged)
            {
                _phase = phase;
                _reportsInPhase = 0;
                force = true;
            }
            var isCompletion = completedFiles == totalFiles;
            var timestamp = _getTimestamp();
            if (!force &&
                (_reportsInPhase >= MaximumNonTerminalProgressReportsPerPhase ||
                 Stopwatch.GetElapsedTime(_lastTimestamp, timestamp) < MinimumInterval))
            {
                return;
            }
            if (!isCompletion && _reportsInPhase >= MaximumNonTerminalProgressReportsPerPhase)
            {
                return;
            }

            _progress.Report(new DuplicateVerificationProgress(phase, completedFiles, totalFiles, currentPath));
            _lastTimestamp = timestamp;
            _reportsInPhase++;
        }
    }

    private readonly record struct Fingerprint(long Size, DateTime LastWriteTimeUtc)
    {
        public static Fingerprint Read(string path)
        {
            var info = new FileInfo(path);
            info.Refresh();
            return new Fingerprint(info.Length, info.LastWriteTimeUtc);
        }
    }
}
