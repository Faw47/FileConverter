import FileConverterCore

public enum ExternalBackendCatalog {
    public static func makeBackends() -> [any ConversionBackend] {
        [FFmpegBackend(), ImageMagickBackend(), LibreOfficeBackend(), GhostscriptBackend()]
    }
}
