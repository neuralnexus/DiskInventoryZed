using System.Security.Cryptography;
using System.Text;
using DiskInventoryZed.Core.Models;
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

public sealed record VerifiedDuplicateGroup(string Digest, long FileSize, IReadOnlyList<FileNode> Files)
{
    public long PotentialSavings => Files.Count < 2
        ? 0
        : Files.Sum(file => file.AllocatedSize) - Files.Min(file => file.AllocatedSize);
    public string DisplayName => $"{Files.Count:N0} verified identical files";
    public string Summary => $"Up to {ByteSizeFormatter.Format(PotentialSavings)} reclaimable";
}

public sealed record DuplicateVerificationResult(
    IReadOnlyList<VerifiedDuplicateGroup> Groups,
    IReadOnlyList<string> UnreadablePaths);

public static class DuplicateVerifier
{
    private const int SampleSize = 64 * 1024;
    private const int ReadBufferSize = 1024 * 1024;

    public static async Task<DuplicateVerificationResult> VerifyAsync(
        IReadOnlyList<DuplicateCandidate> candidates,
        IProgress<DuplicateVerificationProgress>? progress = null,
        CancellationToken cancellationToken = default)
    {
        var files = candidates.SelectMany(candidate => candidate.Files)
            .Where(file => !file.IsHardLinkDuplicate)
            .DistinctBy(file => file.Id, StringComparer.Ordinal)
            .OrderBy(file => file.FullPath, StringComparer.OrdinalIgnoreCase)
            .ToArray();
        var unreadable = new List<string>();
        var samples = new Dictionary<string, List<FileNode>>(StringComparer.Ordinal);

        for (var index = 0; index < files.Length; index++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var file = files[index];
            progress?.Report(new DuplicateVerificationProgress(
                DuplicateVerificationPhase.Sampling,
                index,
                files.Length,
                file.FullPath));
            try
            {
                var digest = await SampleDigestAsync(file, cancellationToken);
                AddToGroup(samples, $"{file.LogicalSize}|{digest}", file);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or CryptographicException)
            {
                if (unreadable.Count < 100)
                {
                    unreadable.Add(file.FullPath);
                }
            }
        }

        var filesToHash = samples.Values.Where(group => group.Count > 1)
            .SelectMany(group => group)
            .OrderBy(file => file.FullPath, StringComparer.OrdinalIgnoreCase)
            .ToArray();
        var fullHashes = new Dictionary<string, List<FileNode>>(StringComparer.Ordinal);
        for (var index = 0; index < filesToHash.Length; index++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var file = filesToHash[index];
            progress?.Report(new DuplicateVerificationProgress(
                DuplicateVerificationPhase.Hashing,
                index,
                filesToHash.Length,
                file.FullPath));
            try
            {
                var digest = await FullDigestAsync(file, cancellationToken);
                AddToGroup(fullHashes, $"{file.LogicalSize}|{digest}", file);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or CryptographicException)
            {
                if (unreadable.Count < 100 && !unreadable.Contains(file.FullPath, StringComparer.OrdinalIgnoreCase))
                {
                    unreadable.Add(file.FullPath);
                }
            }
        }

        var groups = fullHashes
            .Where(item => item.Value.Count > 1)
            .Select(item => new VerifiedDuplicateGroup(
                item.Key[(item.Key.IndexOf('|') + 1)..],
                item.Value[0].LogicalSize,
                item.Value.OrderBy(file => file.FullPath, StringComparer.OrdinalIgnoreCase).ToArray()))
            .OrderByDescending(group => group.PotentialSavings)
            .ThenBy(group => group.Digest, StringComparer.Ordinal)
            .ToArray();
        return new DuplicateVerificationResult(groups, unreadable);
    }

    private static async Task<string> SampleDigestAsync(FileNode node, CancellationToken cancellationToken)
    {
        var before = Fingerprint.Read(node.FullPath);
        if (before.Size != node.LogicalSize)
        {
            throw new IOException("The file changed after it was scanned.");
        }

        await using var stream = OpenRead(node.FullPath);
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        hash.AppendData(Encoding.UTF8.GetBytes(node.LogicalSize.ToString(System.Globalization.CultureInfo.InvariantCulture)));
        var buffer = new byte[SampleSize];
        var expectedCount = (int)Math.Min(SampleSize, node.LogicalSize);
        await stream.ReadExactlyAsync(buffer.AsMemory(0, expectedCount), cancellationToken);
        var count = expectedCount;
        hash.AppendData(buffer, 0, count);
        if (node.LogicalSize > SampleSize)
        {
            stream.Seek(Math.Max(0, node.LogicalSize - SampleSize), SeekOrigin.Begin);
            await stream.ReadExactlyAsync(buffer, cancellationToken);
            count = buffer.Length;
            hash.AppendData(buffer, 0, count);
        }

        var digest = Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant();
        if (Fingerprint.Read(node.FullPath) != before)
        {
            throw new IOException("The file changed while it was being sampled.");
        }

        return digest;
    }

    private static async Task<string> FullDigestAsync(FileNode node, CancellationToken cancellationToken)
    {
        var before = Fingerprint.Read(node.FullPath);
        if (before.Size != node.LogicalSize)
        {
            throw new IOException("The file changed after it was scanned.");
        }

        await using var stream = OpenRead(node.FullPath);
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
        if (Fingerprint.Read(node.FullPath) != before)
        {
            throw new IOException("The file changed while it was being verified.");
        }

        return digest;
    }

    private static FileStream OpenRead(string path)
    {
        var attributes = File.GetAttributes(path);
        if (attributes.HasFlag(FileAttributes.Directory) || attributes.HasFlag(FileAttributes.Offline))
        {
            throw new IOException("Only locally available regular files can be verified.");
        }

        return new FileStream(
            path,
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read | FileShare.Delete,
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
