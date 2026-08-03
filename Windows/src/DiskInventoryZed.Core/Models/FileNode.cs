// Disk Inventory Zed - a modern, fast disk usage visualizer
// Copyright (C) 2026 Matt Ivan. Licensed under GPL-3.0-or-later.

using System.Collections.ObjectModel;

namespace DiskInventoryZed.Core.Models;

public enum FileNodeKind
{
    File,
    Directory,
    Package,
    SymbolicLink
}

/// <summary>An immutable snapshot of one file-system entry.</summary>
public sealed class FileNode : IEquatable<FileNode>
{
    private readonly ReadOnlyCollection<FileNode> _children;

    public FileNode(
        string fullPath,
        string name,
        FileNodeKind kind,
        long logicalSize,
        long allocatedSize,
        IEnumerable<FileNode>? children = null,
        DateTimeOffset? creationDate = null,
        DateTimeOffset? modificationDate = null,
        bool isSymbolicLink = false,
        bool isHardLinkDuplicate = false,
        bool hasUnverifiedHardLinks = false,
        string? issue = null,
        int? totalFileCount = null,
        int? totalDirectoryCount = null,
        bool isUnreadable = false)
    {
        FullPath = fullPath;
        Id = fullPath;
        Name = string.IsNullOrWhiteSpace(name) ? fullPath : name;
        Kind = kind;
        LogicalSize = Math.Max(0, logicalSize);
        AllocatedSize = Math.Max(0, allocatedSize);
        CreationDate = creationDate;
        ModificationDate = modificationDate;
        IsSymbolicLink = isSymbolicLink || kind == FileNodeKind.SymbolicLink;
        IsHardLinkDuplicate = isHardLinkDuplicate;
        HasUnverifiedHardLinks = hasUnverifiedHardLinks;
        IsUnreadable = isUnreadable;
        Issue = issue;

        var childArray = children?.ToArray() ?? [];
        _children = Array.AsReadOnly(childArray);
        TotalFileCount = totalFileCount ?? (IsContainer ? childArray.Sum(child => child.TotalFileCount) : 1);
        TotalDirectoryCount = totalDirectoryCount ??
            (IsContainer ? 1 + childArray.Sum(child => child.TotalDirectoryCount) : 0);
    }

    public string Id { get; }
    public string FullPath { get; }
    public string Name { get; }
    public string DisplayName => Name;
    public FileNodeKind Kind { get; }
    public bool IsDirectory => Kind == FileNodeKind.Directory;
    public bool IsPackage => Kind == FileNodeKind.Package;
    public bool IsContainer => Kind is FileNodeKind.Directory or FileNodeKind.Package;
    public bool IsSymbolicLink { get; }
    public bool IsHardLinkDuplicate { get; }
    public bool HasUnverifiedHardLinks { get; }
    public bool IsUnreadable { get; }
    public string? Issue { get; }
    public string? Extension => IsDirectory
        ? null
        : Path.GetExtension(Name).TrimStart('.') is { Length: > 0 } extension ? extension : null;
    public long LogicalSize { get; }
    public long AllocatedSize { get; }
    public string FormattedSize => Utilities.ByteSizeFormatter.Format(AllocatedSize);
    public string FormattedLogicalSize => Utilities.ByteSizeFormatter.Format(LogicalSize);
    public DateTimeOffset? CreationDate { get; }
    public DateTimeOffset? ModificationDate { get; }
    public IReadOnlyList<FileNode> Children => _children;
    public IReadOnlyList<FileNode> DirectoryChildren => _children.Where(child => child.IsDirectory).ToArray();
    public int TotalFileCount { get; }
    public int TotalDirectoryCount { get; }

    public FileNode? FindById(string targetId)
    {
        var stack = new Stack<FileNode>();
        stack.Push(this);
        while (stack.TryPop(out var node))
        {
            if (PathComparer.Equals(node.Id, targetId))
            {
                return node;
            }

            for (var index = node.Children.Count - 1; index >= 0; index--)
            {
                stack.Push(node.Children[index]);
            }
        }

        return null;
    }

    public IReadOnlyList<FileNode>? PathTo(string targetId)
    {
        var stack = new Stack<FileNode>();
        var nodes = new Dictionary<string, FileNode>(PathComparer) { [Id] = this };
        var parents = new Dictionary<string, string>(PathComparer);
        stack.Push(this);

        while (stack.TryPop(out var node))
        {
            if (PathComparer.Equals(node.Id, targetId))
            {
                var result = new List<FileNode>();
                var cursor = targetId;
                while (nodes.TryGetValue(cursor, out var current))
                {
                    result.Add(current);
                    if (!parents.TryGetValue(cursor, out var parentId))
                    {
                        break;
                    }

                    cursor = parentId;
                }

                result.Reverse();
                return result;
            }

            for (var index = node.Children.Count - 1; index >= 0; index--)
            {
                var child = node.Children[index];
                nodes[child.Id] = child;
                parents[child.Id] = node.Id;
                stack.Push(child);
            }
        }

        return null;
    }

    public bool Equals(FileNode? other) => other is not null && PathComparer.Equals(Id, other.Id);
    public override bool Equals(object? obj) => obj is FileNode other && Equals(other);
    public override int GetHashCode() => PathComparer.GetHashCode(Id);
    public override string ToString() => DisplayName;

    private static StringComparer PathComparer => StringComparer.Ordinal;
}
