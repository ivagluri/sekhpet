using CUE4Parse.FileProvider;
using CUE4Parse.FileProvider.Objects;
using CUE4Parse.UE4.Versions;
using CUE4Parse.UE4.Assets.Exports;
using CUE4Parse.UE4.Assets.Exports.Animation;
using CUE4Parse.UE4.Assets.Exports.SkeletalMesh;
using CUE4Parse.UE4.Assets.Exports.Material;
using CUE4Parse.UE4.Assets.Exports.Texture;
using CUE4Parse_Conversion;
using CUE4Parse_Conversion.Options;
using CUE4Parse.MappingsProvider.Usmap;
using Newtonsoft.Json;
using Serilog;

// Converter <raw> <output> <mappings> <Pal> [AnimSet]   (sources/palworld/make_pet.sh runs it)
if (args.Length < 4)
{
    Console.Error.WriteLine("usage: Converter <raw dir> <output dir> <mappings.usmap> <Pal> [AnimSet]\n" +
                            "       Converter <raw dir> <output.json> <mappings.usmap> --inspect <package>...");
    return 2;
}
var raw = Path.GetFullPath(args[0]);
var output = Path.GetFullPath(args[1]);
var pal = args[3];
// Variants keep their own model folder but use their base pal's animation folder.
var animSet = args.Length > 4 ? args[4] : pal;
if (!(args.Length > 3 && args[3] == "--inspect")) Directory.CreateDirectory(output);
Log.Logger = new LoggerConfiguration().MinimumLevel.Information().WriteTo.Console().CreateLogger();
var versions = new VersionContainer(EGame.GAME_Palworld);
using var provider = new StreamedFileProvider("Pal", versions, StringComparer.OrdinalIgnoreCase);
var files = new Dictionary<string, GameFile>(StringComparer.OrdinalIgnoreCase);
foreach (var path in Directory.EnumerateFiles(raw, "*", SearchOption.AllDirectories))
{
    var file = new FileInfo(path);
    if (!GameFile.UeKnownExtensionsSet.Contains(file.Extension.TrimStart('.').ToUpperInvariant())) continue;
    var gameFile = new OsGameFile(new DirectoryInfo(raw), file, "", versions);
    files[gameFile.Path] = gameFile;
}
provider.Files.AddFiles(files);
if (args.Length > 2) provider.MappingsContainer = new FileUsmapTypeMappingsProvider(args[2]);
Console.WriteLine($"Indexed {provider.Files.Count} loose files; project {provider.ProjectName}");

// Inspection mode: Converter <raw> <output.json> <mappings> --inspect <package path>...
// Dumps each package's exports (properties included) as JSON, without converting anything.
if (args.Length > 4 && args[3] == "--inspect")
{
    var dump = args.Skip(4).ToDictionary(p => p, p => provider.LoadPackage(p).GetExports().ToList());
    File.WriteAllText(output, JsonConvert.SerializeObject(dump, Formatting.Indented));
    Console.WriteLine($"INSPECTED {dump.Count} packages into {output}");
    return 0;
}
var session = new ExportSession { MaxDegreeOfParallelism = 1 };
var catalog = new List<object>();
var failures = new List<object>();
// The mesh's own folder, which for some variants is its base pal's (SK_LilyQueen_Ice is in LilyQueen/).
var meshFile = files.Keys.FirstOrDefault(p => p.EndsWith($"/Model/Character/Monster/{pal}/SK_{pal}.uasset"))
    ?? files.Keys.FirstOrDefault(p => p.Contains("/Model/Character/Monster/") && p.EndsWith($"/SK_{pal}.uasset"));
var modelFolder = meshFile?[..(meshFile.LastIndexOf('/') + 1)] ?? $"/Model/Character/Monster/{pal}/";
foreach (var path in files.Keys.Where(p => p.EndsWith(".uasset") &&
    (p.Contains(modelFolder) || p.Contains($"/Animation/Character/Monster/{animSet}/"))).Order())
{
    try
    {
        foreach (var obj in provider.LoadPackage(path).GetExports())
        {
            catalog.Add(new { path, name = obj.Name, type = obj.ExportType,
                frames = obj is UAnimSequence seq ? seq.NumFrames : (int?)null,
                seconds = obj is UAnimSequenceBase anim ? anim.SequenceLength : (float?)null,
                additive_type = obj is UAnimSequence sequence ? sequence.AdditiveAnimType.ToString() : null,
                reference_pose_type = obj is UAnimSequence sequence2 ? sequence2.RefPoseType.ToString() : null,
                reference_pose = obj is UAnimSequence sequence3 ? sequence3.RefPoseSeq?.ToString() : null });
            // A cooked additive reaction is an overlay, not a standalone pose.
            // Bake its preview onto the reference skeleton; retain its original
            // type in the catalog and leave the raw package unchanged.
            if (obj is UAnimSequence additive && additive.IsValidAdditive() &&
                additive.RefPoseType == EAdditiveBasePoseType.ABPT_LocalAnimFrame)
                additive.RefPoseType = EAdditiveBasePoseType.ABPT_RefPose;
            if (obj is USkeletalMesh or UAnimSequence or UTexture or UMaterialInterface)
                session.Add(obj);
        }
    }
    catch (Exception ex)
    {
        Console.WriteLine($"LOAD FAILED {path}: {ex.Message}");
        failures.Add(new { path, error = ex.ToString() });
    }
}
File.WriteAllText(Path.Combine(output, "package-catalog.json"), JsonConvert.SerializeObject(catalog, Formatting.Indented));
var results = await session.RunAsync(output, new ExportOptions(meshFormat: EMeshFormat.UEFormat));
foreach (var result in results.Where(r => !r.Success))
    failures.Add(new { path = result.ObjectPath, error = result.Error?.ToString() });
File.WriteAllText(Path.Combine(output, "conversion-report.json"), JsonConvert.SerializeObject(new {
    succeeded = results.Count(r => r.Success), failed = failures.Count,
    exports = results.Select(r => new { r.Success, r.ObjectPath, r.DiskFilePaths }), failures
}, Formatting.Indented));
Console.WriteLine($"CONVERSION: {results.Count(r => r.Success)} succeeded; {failures.Count} failures");
return failures.Count > 0 ? 1 : 0;
