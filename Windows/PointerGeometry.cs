using System.Drawing;

namespace LivioRemote.Windows;

internal static class PointerGeometry
{
    public static bool TryMap(Size area, Size image, Point point, out ushort x, out ushort y, bool clamp)
    {
        x = y = 0;
        if (area.Width <= 0 || area.Height <= 0 || image.Width <= 0 || image.Height <= 0) return false;
        // Match the rendered rectangle of PictureBoxSizeMode.Zoom.
        float scale = Math.Min((float)area.Width / image.Width, (float)area.Height / image.Height);
        int width = (int)(scale * image.Width);
        int height = (int)(scale * image.Height);
        if (width <= 0 || height <= 0) return false;
        int dx = point.X - (area.Width - width) / 2;
        int dy = point.Y - (area.Height - height) / 2;
        if (clamp)
        {
            dx = Math.Clamp(dx, 0, width - 1);
            dy = Math.Clamp(dy, 0, height - 1);
        }
        else if (dx < 0 || dx >= width || dy < 0 || dy >= height) return false;
        x = (ushort)Math.Round(dx * 65535.0 / Math.Max(1, width - 1));
        y = (ushort)Math.Round(dy * 65535.0 / Math.Max(1, height - 1));
        return true;
    }
}
