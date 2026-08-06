using System.Globalization;
using System.Runtime.Versioning;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using DiskInventoryZed.Core.Export;
using DiskInventoryZed.Core.Models;

namespace DiskInventoryZed.Core.Tests;

public sealed class ScanExporterAtomicityTests
{
    [Fact]
    public async Task SuccessfulExportReplacesAnExistingDestination()
    {
        using var fixture = new TemporaryDirectory();
        var destination = Path.Combine(fixture.Path, "inventory.csv");
        await File.WriteAllTextAsync(destination, "old-content");

        await ScanExporter.ExportCsvAsync(Tree(), destination);

        var content = await File.ReadAllTextAsync(destination);
        Assert.StartsWith("path,parent_path", content, StringComparison.Ordinal);
        Assert.DoesNotContain("old-content", content, StringComparison.Ordinal);
        Assert.Empty(TemporaryExports(fixture.Path));
    }

    [Fact]
    public async Task CancelledExportPreservesExistingDestinationAndRemovesTemporaryFile()
    {
        using var fixture = new TemporaryDirectory();
        var destination = Path.Combine(fixture.Path, "inventory.csv");
        await File.WriteAllTextAsync(destination, "preserve-me");
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            ScanExporter.ExportCsvAsync(Tree(), destination, cancellation.Token));

        Assert.Equal("preserve-me", await File.ReadAllTextAsync(destination));
        Assert.Empty(TemporaryExports(fixture.Path));
    }

    [Fact]
    public async Task PreCancelledExportDoesNotCreateDestinationDirectory()
    {
        using var fixture = new TemporaryDirectory();
        var directory = Path.Combine(fixture.Path, "not-created");
        var destination = Path.Combine(directory, "inventory.csv");
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            ScanExporter.ExportCsvAsync(Tree(), destination, cancellation.Token));

        Assert.False(Directory.Exists(directory));
    }

    [Fact]
    public async Task CancellationAtCommitBoundaryPreservesExistingDestination()
    {
        using var fixture = new TemporaryDirectory();
        var destination = Path.Combine(fixture.Path, "inventory.csv");
        await File.WriteAllTextAsync(destination, "preserve-me");
        using var cancellation = new CancellationTokenSource();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => ScanExporter.WriteAtomicallyAsync(
            destination,
            async stream => await stream.WriteAsync("replacement"u8.ToArray()),
            cancellation.Token,
            _ =>
            {
                cancellation.Cancel();
                return Task.CompletedTask;
            }));

        Assert.Equal("preserve-me", await File.ReadAllTextAsync(destination));
        Assert.Empty(TemporaryExports(fixture.Path));
    }

    [Fact]
    public async Task CommitFailureLeavesNoTemporaryFile()
    {
        using var fixture = new TemporaryDirectory();
        var destination = Directory.CreateDirectory(Path.Combine(fixture.Path, "destination.csv"));

        await Assert.ThrowsAnyAsync<IOException>(() =>
            ScanExporter.ExportCsvAsync(Tree(), destination.FullName));

        Assert.True(Directory.Exists(destination.FullName));
        Assert.Empty(TemporaryExports(fixture.Path));
    }

    [Fact]
    public async Task LongDestinationNameDoesNotLengthenTemporaryComponent()
    {
        using var fixture = new TemporaryDirectory();
        var destination = Path.Combine(fixture.Path, new string('a', 240) + ".csv");

        await ScanExporter.ExportCsvAsync(Tree(), destination);

        Assert.True(File.Exists(destination));
        Assert.Empty(TemporaryExports(fixture.Path));
    }

    [WindowsFact]
    public async Task ExtendedLengthDestinationCommitsSuccessfully()
    {
        using var fixture = new TemporaryDirectory();
        var directory = fixture.Path;
        while (directory.Length < 280)
        {
            directory = Directory.CreateDirectory(Path.Combine(directory, new string('d', 40))).FullName;
        }
        var destination = Path.Combine(directory, "inventory.csv");

        await ScanExporter.ExportCsvAsync(Tree(), destination);

        Assert.True(File.Exists(destination));
        Assert.Empty(TemporaryExports(directory));
    }

    [WindowsFact]
    public async Task LockedExistingDestinationSurvivesReplaceFailure()
    {
        using var fixture = new TemporaryDirectory();
        var destination = Path.Combine(fixture.Path, "inventory.csv");
        await File.WriteAllTextAsync(destination, "preserve-me");
        await using (var locked = new FileStream(destination, FileMode.Open, FileAccess.Read, FileShare.None))
        {
            await Assert.ThrowsAnyAsync<IOException>(() => ScanExporter.ExportCsvAsync(Tree(), destination));
        }

        Assert.Equal("preserve-me", await File.ReadAllTextAsync(destination));
        Assert.Empty(TemporaryExports(fixture.Path));
    }

    [WindowsFact]
    [SupportedOSPlatform("windows")]
    public async Task StagingFileHasAnExactCallerOnlyAclBeforeCommit()
    {
        using var fixture = new TemporaryDirectory();
        var destination = Path.Combine(fixture.Path, "inventory.csv");
        using var identity = WindowsIdentity.GetCurrent();
        var caller = Assert.IsType<SecurityIdentifier>(identity.User);

        await ScanExporter.WriteAtomicallyAsync(
            destination,
            async stream => await stream.WriteAsync("replacement"u8.ToArray()),
            CancellationToken.None,
            _ =>
            {
                var stagedPath = Assert.Single(TemporaryExports(fixture.Path));
                var security = new FileInfo(stagedPath).GetAccessControl();
                var descriptor = new RawSecurityDescriptor(
                    security.GetSecurityDescriptorBinaryForm(),
                    0);
                var access = Assert.IsType<RawAcl>(descriptor.DiscretionaryAcl);
                var rule = Assert.IsType<CommonAce>(Assert.Single(access.Cast<GenericAce>()));

                Assert.True(descriptor.ControlFlags.HasFlag(ControlFlags.DiscretionaryAclProtected));
                Assert.Equal(caller, descriptor.Owner);
                Assert.Equal(AceFlags.None, rule.AceFlags);
                Assert.Equal(AceQualifier.AccessAllowed, rule.AceQualifier);
                Assert.False(rule.IsCallback);
                Assert.Equal((int)FileSystemRights.FullControl, rule.AccessMask);
                Assert.Equal(caller, rule.SecurityIdentifier);
                return Task.CompletedTask;
            });

        Assert.Equal("replacement", await File.ReadAllTextAsync(destination));
        Assert.Empty(TemporaryExports(fixture.Path));
    }

    [WindowsFact]
    [SupportedOSPlatform("windows")]
    public async Task ExistingDestinationPreservesOwnerDaclAndFilesystemMetadata()
    {
        using var fixture = new TemporaryDirectory();
        var destination = Path.Combine(fixture.Path, "inventory.csv");
        await File.WriteAllTextAsync(destination, "old-content");
        using var identity = WindowsIdentity.GetCurrent();
        var caller = Assert.IsType<SecurityIdentifier>(identity.User);
        var file = new FileInfo(destination);
        var security = file.GetAccessControl();
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        security.AddAccessRule(new FileSystemAccessRule(
            caller,
            FileSystemRights.FullControl,
            AccessControlType.Allow));
        security.AddAccessRule(new FileSystemAccessRule(
            new SecurityIdentifier(WellKnownSidType.WorldSid, null),
            FileSystemRights.ReadData,
            AccessControlType.Allow));
        file.SetAccessControl(security);
        var expectedSecurity = file.GetAccessControl().GetSecurityDescriptorSddlForm(
            AccessControlSections.Owner |
            AccessControlSections.Group |
            AccessControlSections.Access);
        var expectedCreationTime = new DateTime(2020, 2, 3, 4, 5, 6, DateTimeKind.Utc);
        File.SetCreationTimeUtc(destination, expectedCreationTime);
        File.SetAttributes(destination, File.GetAttributes(destination) | FileAttributes.Hidden);
        await File.WriteAllTextAsync(destination + ":metadata", "preserved-stream");

        await ScanExporter.ExportCsvAsync(Tree(), destination);

        var actualSecurity = file.GetAccessControl().GetSecurityDescriptorSddlForm(
            AccessControlSections.Owner |
            AccessControlSections.Group |
            AccessControlSections.Access);
        Assert.Equal(expectedSecurity, actualSecurity);
        Assert.Equal(expectedCreationTime, File.GetCreationTimeUtc(destination));
        Assert.True(File.GetAttributes(destination).HasFlag(FileAttributes.Hidden));
        Assert.Equal("preserved-stream", await File.ReadAllTextAsync(destination + ":metadata"));
        Assert.Empty(TemporaryExports(fixture.Path));
    }

    [WindowsFact]
    [SupportedOSPlatform("windows")]
    public async Task NewDestinationAllowsParentAclInheritanceAfterCommit()
    {
        using var fixture = new TemporaryDirectory();
        var directory = new DirectoryInfo(fixture.Path);
        var inheritedIdentity = new SecurityIdentifier(WellKnownSidType.BuiltinGuestsSid, null);
        var directorySecurity = directory.GetAccessControl();
        directorySecurity.AddAccessRule(new FileSystemAccessRule(
            inheritedIdentity,
            FileSystemRights.ReadData,
            InheritanceFlags.ObjectInherit,
            PropagationFlags.None,
            AccessControlType.Allow));
        directory.SetAccessControl(directorySecurity);
        var controlPath = Path.Combine(fixture.Path, "control.csv");
        await File.WriteAllTextAsync(controlPath, "control");
        var expectedSecurity = new FileInfo(controlPath).GetAccessControl()
            .GetSecurityDescriptorSddlForm(
                AccessControlSections.Owner |
                AccessControlSections.Group |
                AccessControlSections.Access);
        File.Delete(controlPath);
        var destination = Path.Combine(fixture.Path, "inventory.csv");

        await ScanExporter.ExportCsvAsync(Tree(), destination);

        var security = new FileInfo(destination).GetAccessControl();
        var actualSecurity = security.GetSecurityDescriptorSddlForm(
            AccessControlSections.Owner |
            AccessControlSections.Group |
            AccessControlSections.Access);
        var rules = security.GetAccessRules(
            includeExplicit: true,
            includeInherited: true,
            typeof(SecurityIdentifier));
        Assert.False(security.AreAccessRulesProtected);
        Assert.Equal(expectedSecurity, actualSecurity);
        Assert.Contains(rules.Cast<FileSystemAccessRule>(), rule =>
            rule.IsInherited &&
            inheritedIdentity.Equals(rule.IdentityReference) &&
            (rule.FileSystemRights & FileSystemRights.ReadData) != 0);
    }

    [WindowsFact]
    public async Task StagingMutationAtCommitBoundaryIsRejected()
    {
        using var fixture = new TemporaryDirectory();
        var destination = Path.Combine(fixture.Path, "inventory.csv");
        var callbackRan = false;
        Assert.Equal(
            Encoding.UTF8.GetByteCount("replacement"),
            Encoding.UTF8.GetByteCount("tampered!!!"));

        var error = await Assert.ThrowsAnyAsync<IOException>(() => ScanExporter.WriteAtomicallyAsync(
            destination,
            async stream => await stream.WriteAsync("replacement"u8.ToArray()),
            CancellationToken.None,
            async _ =>
            {
                callbackRan = true;
                var stagedPath = Assert.Single(TemporaryExports(fixture.Path));
                await File.WriteAllTextAsync(stagedPath, "tampered!!!");
            }));

        Assert.True(callbackRan);
        Assert.Contains("changed", error.Message, StringComparison.OrdinalIgnoreCase);
        Assert.False(File.Exists(destination));
        Assert.Empty(TemporaryExports(fixture.Path));
    }

    [WindowsFact]
    public async Task ExistingDestinationMutationDuringExportIsRejected()
    {
        using var fixture = new TemporaryDirectory();
        var destination = Path.Combine(fixture.Path, "inventory.csv");
        await File.WriteAllTextAsync(destination, "old-content");
        var callbackRan = false;
        Assert.Equal(
            Encoding.UTF8.GetByteCount("old-content"),
            Encoding.UTF8.GetByteCount("new-content"));

        var error = await Assert.ThrowsAnyAsync<IOException>(() => ScanExporter.WriteAtomicallyAsync(
            destination,
            async stream => await stream.WriteAsync("replacement"u8.ToArray()),
            CancellationToken.None,
            async _ =>
            {
                callbackRan = true;
                await File.WriteAllTextAsync(destination, "new-content");
            }));

        Assert.True(callbackRan);
        Assert.Contains("changed", error.Message, StringComparison.OrdinalIgnoreCase);
        Assert.Equal("new-content", await File.ReadAllTextAsync(destination));
        Assert.Empty(TemporaryExports(fixture.Path));
    }

    [WindowsFact]
    public async Task NewDestinationCreatedDuringExportIsNotOverwritten()
    {
        using var fixture = new TemporaryDirectory();
        var destination = Path.Combine(fixture.Path, "inventory.csv");

        await Assert.ThrowsAnyAsync<IOException>(() => ScanExporter.WriteAtomicallyAsync(
            destination,
            async stream => await stream.WriteAsync("replacement"u8.ToArray()),
            CancellationToken.None,
            async _ => await File.WriteAllTextAsync(destination, "concurrent-content")));

        Assert.Equal("concurrent-content", await File.ReadAllTextAsync(destination));
        Assert.Empty(TemporaryExports(fixture.Path));
    }

    [Fact]
    public async Task CsvIsUtf8WithoutBomAndCultureInvariant()
    {
        using var fixture = new TemporaryDirectory();
        var destination = Path.Combine(fixture.Path, "inventory.csv");
        var previousCulture = CultureInfo.CurrentCulture;
        try
        {
            CultureInfo.CurrentCulture = CultureInfo.GetCultureInfo("fr-FR");
            await ScanExporter.ExportCsvAsync(Tree(), destination);
        }
        finally
        {
            CultureInfo.CurrentCulture = previousCulture;
        }

        var bytes = await File.ReadAllBytesAsync(destination);
        Assert.False(bytes.AsSpan().StartsWith(Encoding.UTF8.Preamble));
        Assert.Contains(",4096,1234,", Encoding.UTF8.GetString(bytes), StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("\tplain.txt")]
    [InlineData("\rplain.txt")]
    [InlineData("\nplain.txt")]
    [InlineData("\uFEFFplain.txt")]
    [InlineData("  \tplain.txt")]
    public async Task CsvNeutralizesHazardousControlPrefixes(string name)
    {
        using var fixture = new TemporaryDirectory();
        var destination = Path.Combine(fixture.Path, "inventory.csv");
        var file = new FileNode(Path.Combine(fixture.Path, name), name, FileNodeKind.File, 1, 1);
        var root = new FileNode(fixture.Path, "fixture", FileNodeKind.Directory, 1, 1, [file]);

        await ScanExporter.ExportCsvAsync(root, destination);

        Assert.Contains($"\"'{name.Replace("\"", "\"\"")}\"", await File.ReadAllTextAsync(destination));
    }

    private static IReadOnlyList<string> TemporaryExports(string directory) =>
        Directory.GetFiles(directory, ".diz-*");

    private static FileNode Tree()
    {
        var file = new FileNode("C:\\fixture\\file.bin", "file.bin", FileNodeKind.File, 1234, 4096);
        return new FileNode("C:\\fixture", "fixture", FileNodeKind.Directory, 1234, 4096, [file]);
    }
}
