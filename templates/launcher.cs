using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;

class WeasisLauncher
{
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int MessageBox(IntPtr hWnd, string text, string caption, uint type);

    [STAThread]
    static void Main()
    {
        string exeDir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        string batPath = Path.Combine(exeDir, "start-weasis.bat");

        if (File.Exists(batPath))
        {
            ProcessStartInfo psi = new ProcessStartInfo();
            psi.FileName = batPath;
            psi.WorkingDirectory = exeDir;
            psi.UseShellExecute = true;
            Process.Start(psi);
        }
        else
        {
            MessageBox(IntPtr.Zero,
                "start-weasis.bat nu a fost gasit!\n\nCale asteptata:\n" + batPath,
                "Weasis Viewer",
                0x10);
        }
    }
}
