import os
import sys
import subprocess
import shutil
import concurrent.futures
import msvcrt
from pathlib import Path

try:
    from colorama import init, Fore, Style
    init(autoreset=True)
except ImportError:
    print("[!] Colorama module absent. Matrix degraded. Execute launch.bat to re-forge.")
    sys.exit(1)

class Colors:
    HEADER, BLUE, GREEN, WARNING, FAIL, END, CYAN, BOLD = (
        Fore.MAGENTA, Fore.BLUE, Fore.GREEN, Fore.YELLOW, Fore.RED, Style.RESET_ALL, Fore.CYAN, Style.BRIGHT
    )
    INV = '\033[7m'
    INV_OFF = '\033[27m'

def getch():
    ch = msvcrt.getwch()
    if ch in ('\x00', '\xe0'):
        ch2 = msvcrt.getwch()
        if ch2 == 'H': return 'UP'
        if ch2 == 'P': return 'DOWN'
        return ch2
    if ch in ('\r', '\n'): return 'ENTER'
    if ch == '\x03': # SOTA FIX: Catch Ctrl+C Keyboard Interrupt
        sys.stdout.write('\033[2J\033[H')
        print(f"{Colors.FAIL}[!] Manual interrupt detected. Matrix terminated.{Colors.END}")
        sys.exit(0)
    return ch

class ExtractoratorMatrix:
    def __init__(self):
        self.base_dir = Path(__file__).parent.resolve()
        self.internals = self.base_dir / ".internals"
        self.workspaces = self.base_dir / "workspaces"
        
        self.payloads_dir = self.workspaces / "01_payloads"
        self.extracted_dir = self.workspaces / "02_extracted"
        self.recovered_dir = self.workspaces / "03_recovered"
        
        self.pycdc_exe = self.internals / "bin" / "pycdc.exe"
        self.pyinstxtractor = self.internals / "library" / "pyinstxtractor.py"

        self._validate_topology()

    def _validate_topology(self):
        missing = []
        if not self.pycdc_exe.exists(): missing.append("pycdc.exe")
        if not self.pyinstxtractor.exists(): missing.append("pyinstxtractor.py")
        
        if missing:
            sys.stdout.write(f"\n{Colors.FAIL}[!] Fatal: Hermetic internals fractured. Missing: {', '.join(missing)}{Colors.END}\n")
            sys.exit(1)
        
        for d in [self.payloads_dir, self.extracted_dir, self.recovered_dir]:
            d.mkdir(parents=True, exist_ok=True)

    def _render_menu(self, options, title):
        current = 0
        while True:
            sys.stdout.write('\033[2J\033[H')
            print(f"{Colors.HEADER}=== {title} ==={Colors.END}\n")
            
            for i, opt in enumerate(options):
                if i == current:
                    print(f"  {Colors.CYAN}{Colors.INV} {opt} {Colors.INV_OFF}{Colors.END}")
                else:
                    print(f"    {opt}")
            
            key = getch()
            if key == 'UP' and current > 0: 
                current -= 1
            elif key == 'DOWN' and current < len(options) - 1: 
                current += 1
            elif key == 'ENTER': 
                return current

    def extract_payload(self):
        payloads = list(self.payloads_dir.rglob("*.exe"))
        if not payloads:
            print(f"\n{Colors.WARNING}[*] Zero .exe payloads localized in workspaces/01_payloads.{Colors.END}")
            self._pause()
            return

        options = [p.name for p in payloads] + ["< Return"]
        sel = self._render_menu(options, "PAYLOAD SELECTION (PHASE 1)")
        if sel == len(options) - 1: return

        target = payloads[sel]
        sys.stdout.write('\033[2J\033[H')
        print(f"{Colors.BLUE}[*] Penetrating PyInstaller envelope: {target.name}{Colors.END}\n")
        
        try:
            subprocess.run(
                [sys.executable, self.pyinstxtractor.as_posix(), target.as_posix()],
                cwd=self.extracted_dir.as_posix(),
                check=True
            )
            print(f"\n{Colors.GREEN}[+] Envelope compromised. Raw bytecode routed to workspaces/02_extracted.{Colors.END}")
        except subprocess.CalledProcessError:
            print(f"\n{Colors.FAIL}[!] Envelope penetration failed. Validate payload architecture.{Colors.END}")
        
        self._pause()

    def _process_ast_node(self, pyc_path: Path, source_root: Path, output_root: Path):
        rel_path = pyc_path.relative_to(source_root)
        out_path = output_root / rel_path.with_suffix(".py")
        out_path.parent.mkdir(parents=True, exist_ok=True)

        try:
            result = subprocess.run(
                [self.pycdc_exe.as_posix(), pyc_path.as_posix()],
                capture_output=True, text=True, check=False
            )
            
            # SOTA FIX: Strict validation. If pycdc encounters unsupported opcodes, it warns in stdout.
            # We save what we can, but flag it if decompilation warns or fails.
            if result.stdout:
                out_path.write_text(result.stdout, encoding='utf-8')
                
            if result.returncode != 0 or "Warning:" in result.stdout or "Unsupported opcode" in result.stdout:
                return (pyc_path, False) # Fractured/Partial
            
            return (pyc_path, True) # Clean
        except Exception:
            return (pyc_path, False)

    def reconstruct_ast(self):
        extracted_targets = [d for d in self.extracted_dir.iterdir() if d.is_dir() and d.name.endswith("_extracted")]
        if not extracted_targets:
            print(f"\n{Colors.WARNING}[*] Zero extracted payloads detected. Execute Phase 1.{Colors.END}")
            self._pause()
            return

        options = [d.name for d in extracted_targets] + ["< Return"]
        sel = self._render_menu(options, "AST RECONSTRUCTION (PHASE 2)")
        if sel == len(options) - 1: return

        source_root = extracted_targets[sel]
        out_name = source_root.name.replace("_extracted", "_recovered")
        output_root = self.recovered_dir / out_name

        if output_root.exists():
            shutil.rmtree(output_root)
        output_root.mkdir(parents=True, exist_ok=True)

        pyc_files = list(source_root.rglob("*.pyc"))
        total = len(pyc_files)

        sys.stdout.write('\033[2J\033[H')
        if total == 0:
            print(f"{Colors.FAIL}[!] Zero valid bytecode structures detected in {source_root.name}.{Colors.END}")
            self._pause()
            return

        print(f"{Colors.BLUE}[*] Initiating parallel AST translation matrix across {total} nodes...{Colors.END}\n")

        successful_nodes = []
        fractured_nodes = []

        with concurrent.futures.ThreadPoolExecutor() as executor:
            futures = {executor.submit(self._process_ast_node, pyc, source_root, output_root): pyc for pyc in pyc_files}
            for future in concurrent.futures.as_completed(futures):
                pyc_path, success = future.result()
                if success:
                    successful_nodes.append(pyc_path)
                else:
                    fractured_nodes.append(pyc_path)
                
                processed = len(successful_nodes) + len(fractured_nodes)
                sys.stdout.write(f"\r{Colors.CYAN}[*] Translating AST: {processed}/{total} nodes resolved.{Colors.END}")
                sys.stdout.flush()

        # SOTA FIX: Generate Diagnostic Ledger
        audit_log = output_root / "_recovery_audit.log"
        with open(audit_log, "w", encoding="utf-8") as f:
            f.write("=== EXTRACTORATOR AST RECONSTRUCTION LEDGER ===\n")
            f.write(f"Target: {source_root.name}\n")
            f.write(f"Total Nodes: {total} | Recovered: {len(successful_nodes)} | Fractured: {len(fractured_nodes)}\n\n")
            
            if fractured_nodes:
                f.write("[!] FRACTURED / PARTIAL NODES (Manual Assembly Inspection Required via pycdas.exe):\n")
                for node in fractured_nodes:
                    f.write(f"  - {node.relative_to(source_root)}\n")
                f.write("\n")
            
            f.write("[+] CLEAN RECOVERED NODES:\n")
            for node in successful_nodes:
                f.write(f"  - {node.relative_to(source_root)}\n")

        print(f"\n\n{Colors.GREEN}[+] Reconstruction cycle absolute. Yield: {len(successful_nodes)} Recovered / {len(fractured_nodes)} Fractured.{Colors.END}")
        print(f"{Colors.GREEN}[+] Matrix mapped to: {output_root.relative_to(self.base_dir)}{Colors.END}")
        print(f"{Colors.WARNING}[*] Diagnostic Ledger generated: _recovery_audit.log{Colors.END}")
        self._pause()

    def sanitize_workspace(self):
        options = ["Purge Phase 1 Outputs (02_extracted)", "Purge Phase 2 Outputs (03_recovered)", "Total Eradication (Both)", "< Return"]
        sel = self._render_menu(options, "WORKSPACE SANITIZATION")
        
        try:
            if sel == 0 or sel == 2:
                for item in self.extracted_dir.iterdir():
                    shutil.rmtree(item) if item.is_dir() else item.unlink()
            if sel == 1 or sel == 2:
                for item in self.recovered_dir.iterdir():
                    shutil.rmtree(item) if item.is_dir() else item.unlink()
                    
            if sel != 3:
                print(f"\n{Colors.GREEN}[+] Garbage collection absolute. I/O matrix sterilized.{Colors.END}")
                self._pause()
        except Exception as e:
            print(f"\n{Colors.FAIL}[!] GC Error: {e}{Colors.END}")
            self._pause()

    def _pause(self):
        print(f"\n{Colors.BOLD}Press any key to initiate return...{Colors.END}")
        getch()

    def boot(self):
        main_options = [
            "1. Extract Payload (.exe -> .pyc)",
            "2. Reconstruct AST (.pyc -> .py)",
            "3. Workspace Sanitization (GC)",
            "4. Terminate Matrix"
        ]
        while True:
            sel = self._render_menu(main_options, "EXTRACTORATOR OS ENGINE")
            if sel == 0: self.extract_payload()
            elif sel == 1: self.reconstruct_ast()
            elif sel == 2: self.sanitize_workspace()
            elif sel == 3:
                sys.stdout.write('\033[2J\033[H')
                sys.exit(0)

if __name__ == "__main__":
    engine = ExtractoratorMatrix()
    engine.boot()