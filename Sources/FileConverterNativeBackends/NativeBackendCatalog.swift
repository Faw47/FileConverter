import FileConverterCore

public enum NativeBackendCatalog {
    public static func makeBackends() -> [any ConversionBackend] {
        [ImageIOBackend(), PDFKitBackend(), AVFoundationBackend()]
    }
}
