using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Microsoft.Win32.SafeHandles;

namespace Ccdi.Acceptance
{
    public sealed class ConPtyProcess : IDisposable
    {
        private const uint EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
        private const uint PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = 0x00020016;
        private const uint PROC_THREAD_ATTRIBUTE_JOB_LIST = 0x0002000D;
        private const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
        private const int JobObjectExtendedLimitInformation = 9;
        private const uint WAIT_OBJECT_0 = 0;
        private const uint WAIT_TIMEOUT = 258;
        private const uint INFINITE = 0xffffffff;
        private const uint STILL_ACTIVE = 259;
        private const int STD_INPUT_HANDLE = -10;
        private const int STD_OUTPUT_HANDLE = -11;
        private const int STD_ERROR_HANDLE = -12;
        private static readonly object ProcessCreationLock = new object();

        private IntPtr pseudoConsole = IntPtr.Zero;
        private IntPtr pseudoInputHandle = IntPtr.Zero;
        private IntPtr pseudoOutputHandle = IntPtr.Zero;
        private IntPtr processHandle = IntPtr.Zero;
        private IntPtr jobHandle = IntPtr.Zero;
        private SafeFileHandle inputHandle;
        private SafeFileHandle outputHandle;
        private FileStream inputStream;
        private StreamReader outputReader;
        private Thread outputThread;
        private readonly StringBuilder output = new StringBuilder();
        private readonly object outputLock = new object();
        private volatile bool disposed;
        private volatile bool outputCompleted;
        private Exception outputError;

        public int ProcessId { get; private set; }
        public bool JobAssigned { get; private set; }

        public static ConPtyProcess Start(string commandLine, string workingDirectory, short columns, short rows)
        {
            if (String.IsNullOrWhiteSpace(commandLine))
                throw new ArgumentException("commandLine is required", "commandLine");

            ConPtyProcess instance = new ConPtyProcess();
            instance.StartInternal(commandLine, workingDirectory, columns, rows);
            return instance;
        }

        private void StartInternal(string commandLine, string workingDirectory, short columns, short rows)
        {
            IntPtr pseudoInputRead = IntPtr.Zero;
            IntPtr hostInputWrite = IntPtr.Zero;
            IntPtr hostOutputRead = IntPtr.Zero;
            IntPtr pseudoOutputWrite = IntPtr.Zero;
            IntPtr attributeList = IntPtr.Zero;
            IntPtr jobListValue = IntPtr.Zero;
            PROCESS_INFORMATION processInfo = new PROCESS_INFORMATION();

            try
            {
                Check(CreatePipe(out pseudoInputRead, out hostInputWrite, IntPtr.Zero, 0), "CreatePipe(input)");
                Check(CreatePipe(out hostOutputRead, out pseudoOutputWrite, IntPtr.Zero, 0), "CreatePipe(output)");

                COORD size = new COORD();
                size.X = columns;
                size.Y = rows;
                int hr = CreatePseudoConsole(size, pseudoInputRead, pseudoOutputWrite, 0, out pseudoConsole);
                if (hr != 0)
                    Marshal.ThrowExceptionForHR(hr);
                pseudoInputHandle = pseudoInputRead;
                pseudoInputRead = IntPtr.Zero;
                pseudoOutputHandle = pseudoOutputWrite;
                pseudoOutputWrite = IntPtr.Zero;

                CreateKillOnCloseJob();

                IntPtr attributeListSize = IntPtr.Zero;
                InitializeProcThreadAttributeList(IntPtr.Zero, 2, 0, ref attributeListSize);
                attributeList = Marshal.AllocHGlobal(attributeListSize);
                Check(InitializeProcThreadAttributeList(attributeList, 2, 0, ref attributeListSize), "InitializeProcThreadAttributeList");

                Check(UpdateProcThreadAttribute(
                    attributeList,
                    0,
                    new IntPtr(PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE),
                    pseudoConsole,
                    new IntPtr(IntPtr.Size),
                     IntPtr.Zero,
                     IntPtr.Zero), "UpdateProcThreadAttribute");

                jobListValue = Marshal.AllocHGlobal(IntPtr.Size);
                Marshal.WriteIntPtr(jobListValue, jobHandle);
                Check(UpdateProcThreadAttribute(
                    attributeList,
                    0,
                    new IntPtr(PROC_THREAD_ATTRIBUTE_JOB_LIST),
                    jobListValue,
                    new IntPtr(IntPtr.Size),
                    IntPtr.Zero,
                    IntPtr.Zero), "UpdateProcThreadAttribute(job list)");

                STARTUPINFOEX startupInfo = new STARTUPINFOEX();
                startupInfo.StartupInfo.cb = Marshal.SizeOf(typeof(STARTUPINFOEX));
                startupInfo.lpAttributeList = attributeList;
                SECURITY_ATTRIBUTES processAttributes = new SECURITY_ATTRIBUTES();
                processAttributes.nLength = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES));
                SECURITY_ATTRIBUTES threadAttributes = new SECURITY_ATTRIBUTES();
                threadAttributes.nLength = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES));

                uint flags = EXTENDED_STARTUPINFO_PRESENT;
                lock (ProcessCreationLock)
                {
                    IntPtr oldInput = GetStdHandle(STD_INPUT_HANDLE);
                    IntPtr oldOutput = GetStdHandle(STD_OUTPUT_HANDLE);
                    IntPtr oldError = GetStdHandle(STD_ERROR_HANDLE);
                    try
                    {
                        SetStdHandle(STD_INPUT_HANDLE, IntPtr.Zero);
                        SetStdHandle(STD_OUTPUT_HANDLE, IntPtr.Zero);
                        SetStdHandle(STD_ERROR_HANDLE, IntPtr.Zero);
                        Check(CreateProcessW(
                            null,
                            commandLine,
                            ref processAttributes,
                            ref threadAttributes,
                            false,
                            flags,
                            IntPtr.Zero,
                            workingDirectory,
                            ref startupInfo,
                            out processInfo), "CreateProcessW");
                    }
                    finally
                    {
                        SetStdHandle(STD_INPUT_HANDLE, oldInput);
                        SetStdHandle(STD_OUTPUT_HANDLE, oldOutput);
                        SetStdHandle(STD_ERROR_HANDLE, oldError);
                    }
                }

                processHandle = processInfo.hProcess;
                ProcessId = unchecked((int)processInfo.dwProcessId);
                JobAssigned = true;
                CloseHandle(processInfo.hThread);
                processInfo.hThread = IntPtr.Zero;

                inputHandle = new SafeFileHandle(hostInputWrite, true);
                hostInputWrite = IntPtr.Zero;
                outputHandle = new SafeFileHandle(hostOutputRead, true);
                hostOutputRead = IntPtr.Zero;
                inputStream = new FileStream(inputHandle, FileAccess.Write, 4096, false);
                outputReader = new StreamReader(
                    new FileStream(outputHandle, FileAccess.Read, 4096, false),
                    new UTF8Encoding(false, false),
                    true,
                    4096,
                    false);

                outputThread = new Thread(ReadOutputLoop);
                outputThread.IsBackground = true;
                outputThread.Name = "CCDI ConPTY output";
                outputThread.Start();
            }
            catch
            {
                Dispose();
                throw;
            }
            finally
            {
                if (processInfo.hThread != IntPtr.Zero) CloseHandle(processInfo.hThread);
                if (pseudoInputRead != IntPtr.Zero) CloseHandle(pseudoInputRead);
                if (hostInputWrite != IntPtr.Zero) CloseHandle(hostInputWrite);
                if (hostOutputRead != IntPtr.Zero) CloseHandle(hostOutputRead);
                if (pseudoOutputWrite != IntPtr.Zero) CloseHandle(pseudoOutputWrite);
                if (jobListValue != IntPtr.Zero) Marshal.FreeHGlobal(jobListValue);
                if (attributeList != IntPtr.Zero)
                {
                    DeleteProcThreadAttributeList(attributeList);
                    Marshal.FreeHGlobal(attributeList);
                }
            }
        }

        private void CreateKillOnCloseJob()
        {
            jobHandle = CreateJobObject(IntPtr.Zero, null);
            if (jobHandle == IntPtr.Zero)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateJobObject failed");

            JOBOBJECT_EXTENDED_LIMIT_INFORMATION info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
            info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            int length = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
            IntPtr buffer = Marshal.AllocHGlobal(length);
            try
            {
                Marshal.StructureToPtr(info, buffer, false);
                if (!SetInformationJobObject(jobHandle, JobObjectExtendedLimitInformation, buffer, (uint)length))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "SetInformationJobObject failed");
                }
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
        }

        private void ReadOutputLoop()
        {
            char[] buffer = new char[2048];
            try
            {
                while (!disposed)
                {
                    int count = outputReader.Read(buffer, 0, buffer.Length);
                    if (count <= 0) break;
                    lock (outputLock)
                    {
                        output.Append(buffer, 0, count);
                    }
                }
            }
            catch (Exception ex)
            {
                if (!disposed) outputError = ex;
            }
            finally
            {
                outputCompleted = true;
            }
        }

        public string GetOutput()
        {
            lock (outputLock)
            {
                return output.ToString();
            }
        }

        public void Write(string text)
        {
            if (disposed) throw new ObjectDisposedException("ConPtyProcess");
            if (inputStream == null) throw new InvalidOperationException("ConPTY input is unavailable");
            byte[] bytes = new UTF8Encoding(false).GetBytes(text ?? String.Empty);
            inputStream.Write(bytes, 0, bytes.Length);
            inputStream.Flush();
        }

        public void CloseInput()
        {
            if (inputStream != null)
            {
                inputStream.Dispose();
                inputStream = null;
            }
        }

        public bool HasExited
        {
            get
            {
                if (processHandle == IntPtr.Zero) return true;
                return WaitForSingleObject(processHandle, 0) == WAIT_OBJECT_0;
            }
        }

        public bool WaitForExit(int milliseconds)
        {
            if (processHandle == IntPtr.Zero) return true;
            uint timeout = milliseconds < 0 ? INFINITE : unchecked((uint)milliseconds);
            uint result = WaitForSingleObject(processHandle, timeout);
            if (result == WAIT_OBJECT_0)
            {
                if (outputThread != null) outputThread.Join(5000);
                return true;
            }
            if (result == WAIT_TIMEOUT) return false;
            throw new Win32Exception(Marshal.GetLastWin32Error(), "WaitForSingleObject failed");
        }

        public int ExitCode
        {
            get
            {
                if (processHandle == IntPtr.Zero) throw new InvalidOperationException("Process is unavailable");
                uint code;
                Check(GetExitCodeProcess(processHandle, out code), "GetExitCodeProcess");
                if (code == STILL_ACTIVE) throw new InvalidOperationException("Process has not exited");
                return unchecked((int)code);
            }
        }

        public string OutputError
        {
            get { return outputError == null ? null : outputError.ToString(); }
        }

        public bool OutputCompleted
        {
            get { return outputCompleted; }
        }

        public void Terminate(int exitCode)
        {
            if (processHandle == IntPtr.Zero || HasExited) return;
            if (jobHandle != IntPtr.Zero && JobAssigned)
            {
                TerminateJobObject(jobHandle, unchecked((uint)exitCode));
            }
            else
            {
                TerminateProcess(processHandle, unchecked((uint)exitCode));
            }
            WaitForExit(5000);
        }

        public void Dispose()
        {
            if (disposed) return;
            disposed = true;

            try
            {
                if (processHandle != IntPtr.Zero && !HasExited) Terminate(143);
            }
            catch { }
            try { if (inputStream != null) inputStream.Dispose(); } catch { }
            inputStream = null;
            try { if (outputReader != null) outputReader.Dispose(); } catch { }
            outputReader = null;
            try { if (outputThread != null) outputThread.Join(1000); } catch { }
            if (processHandle != IntPtr.Zero) { CloseHandle(processHandle); processHandle = IntPtr.Zero; }
            if (jobHandle != IntPtr.Zero) { CloseHandle(jobHandle); jobHandle = IntPtr.Zero; }
            if (pseudoConsole != IntPtr.Zero) { ClosePseudoConsole(pseudoConsole); pseudoConsole = IntPtr.Zero; }
            if (pseudoInputHandle != IntPtr.Zero) { CloseHandle(pseudoInputHandle); pseudoInputHandle = IntPtr.Zero; }
            if (pseudoOutputHandle != IntPtr.Zero) { CloseHandle(pseudoOutputHandle); pseudoOutputHandle = IntPtr.Zero; }
            if (inputHandle != null && !inputHandle.IsClosed) inputHandle.Dispose();
            if (outputHandle != null && !outputHandle.IsClosed) outputHandle.Dispose();
        }

        private static void Check(bool success, string operation)
        {
            if (!success) throw new Win32Exception(Marshal.GetLastWin32Error(), operation + " failed");
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct COORD { public short X; public short Y; }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct STARTUPINFO
        {
            public int cb;
            public string lpReserved;
            public string lpDesktop;
            public string lpTitle;
            public int dwX;
            public int dwY;
            public int dwXSize;
            public int dwYSize;
            public int dwXCountChars;
            public int dwYCountChars;
            public int dwFillAttribute;
            public int dwFlags;
            public short wShowWindow;
            public short cbReserved2;
            public IntPtr lpReserved2;
            public IntPtr hStdInput;
            public IntPtr hStdOutput;
            public IntPtr hStdError;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct STARTUPINFOEX { public STARTUPINFO StartupInfo; public IntPtr lpAttributeList; }

        [StructLayout(LayoutKind.Sequential)]
        private struct PROCESS_INFORMATION
        {
            public IntPtr hProcess;
            public IntPtr hThread;
            public uint dwProcessId;
            public uint dwThreadId;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct SECURITY_ATTRIBUTES
        {
            public int nLength;
            public IntPtr lpSecurityDescriptor;
            public int bInheritHandle;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct IO_COUNTERS
        {
            public ulong ReadOperationCount;
            public ulong WriteOperationCount;
            public ulong OtherOperationCount;
            public ulong ReadTransferCount;
            public ulong WriteTransferCount;
            public ulong OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
        {
            public long PerProcessUserTimeLimit;
            public long PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize;
            public UIntPtr MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass;
            public uint SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
        {
            public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
            public IO_COUNTERS IoInfo;
            public UIntPtr ProcessMemoryLimit;
            public UIntPtr JobMemoryLimit;
            public UIntPtr PeakProcessMemoryUsed;
            public UIntPtr PeakJobMemoryUsed;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CreatePipe(out IntPtr readPipe, out IntPtr writePipe, IntPtr pipeAttributes, int size);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr GetStdHandle(int standardHandle);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetStdHandle(int standardHandle, IntPtr handle);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern int CreatePseudoConsole(COORD size, IntPtr input, IntPtr output, uint flags, out IntPtr pseudoConsole);

        [DllImport("kernel32.dll")]
        private static extern void ClosePseudoConsole(IntPtr pseudoConsole);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool InitializeProcThreadAttributeList(IntPtr attributeList, int attributeCount, int flags, ref IntPtr size);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool UpdateProcThreadAttribute(IntPtr attributeList, uint flags, IntPtr attribute, IntPtr value, IntPtr size, IntPtr previousValue, IntPtr returnSize);

        [DllImport("kernel32.dll")]
        private static extern void DeleteProcThreadAttributeList(IntPtr attributeList);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CreateProcessW(
            string applicationName,
            string commandLine,
            ref SECURITY_ATTRIBUTES processAttributes,
            ref SECURITY_ATTRIBUTES threadAttributes,
            bool inheritHandles,
            uint creationFlags,
            IntPtr environment,
            string currentDirectory,
            [In] ref STARTUPINFOEX startupInfo,
            out PROCESS_INFORMATION processInformation);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool TerminateProcess(IntPtr process, uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr CreateJobObject(IntPtr jobAttributes, string name);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetInformationJobObject(IntPtr job, int informationClass, IntPtr information, uint informationLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool TerminateJobObject(IntPtr job, uint exitCode);
    }

    public static class WindowsCredential
    {
        private const uint CRED_TYPE_GENERIC = 1;
        private const uint CRED_PERSIST_LOCAL_MACHINE = 2;

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct CREDENTIAL
        {
            public uint Flags;
            public uint Type;
            public IntPtr TargetName;
            public IntPtr Comment;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
            public uint CredentialBlobSize;
            public IntPtr CredentialBlob;
            public uint Persist;
            public uint AttributeCount;
            public IntPtr Attributes;
            public IntPtr TargetAlias;
            public IntPtr UserName;
        }

        public static string ReadGeneric(string targetName)
        {
            IntPtr credentialPointer;
            if (!CredReadW(targetName, CRED_TYPE_GENERIC, 0, out credentialPointer))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Credential not found: " + targetName);
            try
            {
                CREDENTIAL credential = (CREDENTIAL)Marshal.PtrToStructure(credentialPointer, typeof(CREDENTIAL));
                if (credential.CredentialBlob == IntPtr.Zero || credential.CredentialBlobSize == 0)
                    return String.Empty;
                return Marshal.PtrToStringUni(credential.CredentialBlob, checked((int)credential.CredentialBlobSize / 2));
            }
            finally
            {
                CredFree(credentialPointer);
            }
        }

        public static void WriteGeneric(string targetName, string userName, string secret)
        {
            byte[] blob = Encoding.Unicode.GetBytes(secret ?? String.Empty);
            IntPtr targetPointer = IntPtr.Zero;
            IntPtr userPointer = IntPtr.Zero;
            IntPtr blobPointer = IntPtr.Zero;
            try
            {
                targetPointer = Marshal.StringToCoTaskMemUni(targetName);
                userPointer = Marshal.StringToCoTaskMemUni(String.IsNullOrWhiteSpace(userName) ? "CCDI Acceptance" : userName);
                blobPointer = Marshal.AllocCoTaskMem(blob.Length);
                if (blob.Length > 0) Marshal.Copy(blob, 0, blobPointer, blob.Length);

                CREDENTIAL credential = new CREDENTIAL();
                credential.Type = CRED_TYPE_GENERIC;
                credential.TargetName = targetPointer;
                credential.UserName = userPointer;
                credential.CredentialBlobSize = unchecked((uint)blob.Length);
                credential.CredentialBlob = blobPointer;
                credential.Persist = CRED_PERSIST_LOCAL_MACHINE;
                if (!CredWriteW(ref credential, 0))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Failed to write credential: " + targetName);
            }
            finally
            {
                Array.Clear(blob, 0, blob.Length);
                if (blobPointer != IntPtr.Zero)
                {
                    for (int i = 0; i < blob.Length; i++) Marshal.WriteByte(blobPointer, i, 0);
                    Marshal.FreeCoTaskMem(blobPointer);
                }
                if (targetPointer != IntPtr.Zero) Marshal.FreeCoTaskMem(targetPointer);
                if (userPointer != IntPtr.Zero) Marshal.FreeCoTaskMem(userPointer);
            }
        }

        public static void DeleteGeneric(string targetName)
        {
            if (!CredDeleteW(targetName, CRED_TYPE_GENERIC, 0))
            {
                int error = Marshal.GetLastWin32Error();
                if (error != 1168) throw new Win32Exception(error, "Failed to delete credential: " + targetName);
            }
        }

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CredReadW(string target, uint type, uint flags, out IntPtr credential);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CredWriteW(ref CREDENTIAL credential, uint flags);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CredDeleteW(string target, uint type, uint flags);

        [DllImport("advapi32.dll")]
        private static extern void CredFree(IntPtr buffer);
    }
}
