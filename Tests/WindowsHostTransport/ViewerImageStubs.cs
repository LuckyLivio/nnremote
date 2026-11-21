namespace LivioRemote.Windows;

// Exercise the production viewer transport on all platforms without decoding JPEGs.
internal sealed class Bitmap : IDisposable
{
    public Bitmap(Image _) => throw new NotSupportedException("Image decoding requires Windows.");
    public void Dispose() { }
}

internal sealed class Image : IDisposable
{
    public static Image FromStream(Stream _, bool useEmbeddedColorManagement, bool validateImageData) =>
        throw new NotSupportedException("Image decoding requires Windows.");
    public void Dispose() { }
}
