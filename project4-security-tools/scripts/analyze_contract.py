#!/usr/bin/env python3
"""
Sui Move Smart Contract Security Analyzer

Performs static analysis on Sui Move smart contracts to identify
common security vulnerabilities and code quality issues.
"""

import re
import sys
from pathlib import Path
from typing import List, Dict, Tuple
from dataclasses import dataclass
from enum import Enum


class Severity(Enum):
    CRITICAL = "🔴 CRITICAL"
    HIGH = "🟠 HIGH"
    MEDIUM = "🟡 MEDIUM"
    LOW = "🟢 LOW"
    INFO = "ℹ️  INFO"


@dataclass
class Finding:
    severity: Severity
    title: str
    description: str
    file: str
    line: int
    code_snippet: str
    recommendation: str


class SuiMoveAnalyzer:
    def __init__(self, source_dir: Path):
        self.source_dir = source_dir
        self.findings: List[Finding] = []

    def analyze(self) -> List[Finding]:
        """Run all security checks"""
        print(f"🔍 Analyzing contracts in: {self.source_dir}")

        move_files = list(self.source_dir.rglob("*.move"))
        print(f"📁 Found {len(move_files)} Move files\n")

        for file_path in move_files:
            self.analyze_file(file_path)

        return self.findings

    def analyze_file(self, file_path: Path):
        """Analyze a single Move file"""
        print(f"Analyzing: {file_path.name}")

        with open(file_path, 'r') as f:
            content = f.read()
            lines = content.split('\n')

        self.check_access_control(file_path, content, lines)
        self.check_arithmetic_safety(file_path, content, lines)
        self.check_asset_handling(file_path, content, lines)
        self.check_test_coverage(file_path, content, lines)
        self.check_event_emissions(file_path, content, lines)
        self.check_dos_vectors(file_path, content, lines)
        self.check_precision_issues(file_path, content, lines)

    def check_access_control(self, file_path: Path, content: str, lines: List[str]):
        """Check for access control issues"""

        # Check for hardcoded addresses
        pattern = r'ctx\.sender\(\)\s*==\s*@0x[a-fA-F0-9]+'
        matches = re.finditer(pattern, content)
        for match in matches:
            line_num = content[:match.start()].count('\n') + 1
            self.findings.append(Finding(
                severity=Severity.HIGH,
                title="Hardcoded Address Authorization",
                description="Using hardcoded addresses for authorization is insecure",
                file=str(file_path),
                line=line_num,
                code_snippet=lines[line_num - 1].strip(),
                recommendation="Use capability-based access control with Cap objects"
            ))

        # Check for public entry functions without checks
        pattern = r'public\s+entry\s+fun\s+(\w+)\s*<[^>]*>\s*\([^)]*\)\s*\{'
        matches = re.finditer(pattern, content)
        for match in matches:
            func_name = match.group(1)
            if any(keyword in func_name.lower() for keyword in ['admin', 'owner', 'pause', 'update', 'set']):
                # Check if function has capability parameter
                func_start = match.start()
                func_end = content.find('}', func_start)
                func_body = content[func_start:func_end]

                if 'Cap' not in func_body or '_cap' not in func_body.lower():
                    line_num = content[:match.start()].count('\n') + 1
                    self.findings.append(Finding(
                        severity=Severity.CRITICAL,
                        title="Missing Access Control on Admin Function",
                        description=f"Admin function '{func_name}' lacks capability check",
                        file=str(file_path),
                        line=line_num,
                        code_snippet=lines[line_num - 1].strip(),
                        recommendation="Add AdminCap or similar capability parameter"
                    ))

    def check_arithmetic_safety(self, file_path: Path, content: str, lines: List[str]):
        """Check for arithmetic safety issues"""

        # Check for divisions
        pattern = r'(\w+)\s*/\s*(\w+)'
        matches = re.finditer(pattern, content)
        for match in matches:
            divisor = match.group(2)
            line_num = content[:match.start()].count('\n') + 1

            # Look for zero check in surrounding lines
            surrounding = '\n'.join(lines[max(0, line_num-3):min(len(lines), line_num+3)])
            if f'assert!({divisor}' not in surrounding and f'{divisor} >' not in surrounding and f'{divisor} !=' not in surrounding:
                self.findings.append(Finding(
                    severity=Severity.MEDIUM,
                    title="Potential Division by Zero",
                    description=f"Division by '{divisor}' without visible zero check",
                    file=str(file_path),
                    line=line_num,
                    code_snippet=lines[line_num - 1].strip(),
                    recommendation="Add assertion: assert!(divisor != 0, ERROR_CODE)"
                ))

        # Check for multiplication order (precision)
        pattern = r'(\w+)\s*/\s*(\w+)\s*\*\s*(\w+)'
        matches = re.finditer(pattern, content)
        for match in matches:
            line_num = content[:match.start()].count('\n') + 1
            self.findings.append(Finding(
                severity=Severity.LOW,
                title="Potential Precision Loss",
                description="Division before multiplication can cause precision loss",
                file=str(file_path),
                line=line_num,
                code_snippet=lines[line_num - 1].strip(),
                recommendation="Perform multiplication before division: (a * c) / b"
            ))

    def check_asset_handling(self, file_path: Path, content: str, lines: List[str]):
        """Check for asset handling issues"""

        # Check for balance operations without value checks
        pattern = r'balance::split\(&mut\s+[\w.]+,\s*(\w+)\)'
        matches = re.finditer(pattern, content)
        for match in matches:
            amount_var = match.group(1)
            line_num = content[:match.start()].count('\n') + 1

            # Look for balance check before split
            preceding = '\n'.join(lines[max(0, line_num-5):line_num])
            if 'balance::value' not in preceding and amount_var not in preceding:
                self.findings.append(Finding(
                    severity=Severity.HIGH,
                    title="Unchecked Balance Split",
                    description=f"balance::split called without verifying sufficient balance",
                    file=str(file_path),
                    line=line_num,
                    code_snippet=lines[line_num - 1].strip(),
                    recommendation="Check balance before split: assert!(balance::value(&balance) >= amount, ...)"
                ))

    def check_test_coverage(self, file_path: Path, content: str, lines: List[str]):
        """Check for test coverage"""

        # Count public functions
        public_funcs = len(re.findall(r'public\s+(entry\s+)?fun\s+\w+', content))

        # Count test functions
        test_funcs = len(re.findall(r'#\[test\]', content))

        if public_funcs > 0 and test_funcs == 0 and '#[test_only]' not in content:
            self.findings.append(Finding(
                severity=Severity.MEDIUM,
                title="Missing Test Coverage",
                description=f"Module has {public_funcs} public functions but no tests",
                file=str(file_path),
                line=1,
                code_snippet="",
                recommendation="Add comprehensive unit tests for all public functions"
            ))

    def check_event_emissions(self, file_path: Path, content: str, lines: List[str]):
        """Check for event emissions on state changes"""

        # Find state-changing patterns
        patterns = [
            r'balance::join',
            r'balance::split',
            r'transfer::transfer',
            r'transfer::public_transfer'
        ]

        for pattern in patterns:
            matches = re.finditer(pattern, content)
            for match in matches:
                line_num = content[:match.start()].count('\n') + 1

                # Check if event::emit is nearby
                surrounding = '\n'.join(lines[max(0, line_num-2):min(len(lines), line_num+3)])
                if 'event::emit' not in surrounding:
                    self.findings.append(Finding(
                        severity=Severity.LOW,
                        title="Missing Event Emission",
                        description=f"State change ({match.group()}) without event emission",
                        file=str(file_path),
                        line=line_num,
                        code_snippet=lines[line_num - 1].strip(),
                        recommendation="Emit event after state changes for off-chain tracking"
                    ))
                    break  # Only report once per function

    def check_dos_vectors(self, file_path: Path, content: str, lines: List[str]):
        """Check for denial of service vectors"""

        # Check for unbounded loops
        pattern = r'while\s*\([^)]+\)\s*\{'
        matches = re.finditer(pattern, content)
        for match in matches:
            line_num = content[:match.start()].count('\n') + 1
            loop_content = lines[line_num - 1]

            # Check if there's a length check
            if 'length' in loop_content and 'MAX' not in content[max(0, match.start()-200):match.start()]:
                self.findings.append(Finding(
                    severity=Severity.MEDIUM,
                    title="Potentially Unbounded Loop",
                    description="Loop without visible maximum iteration limit",
                    file=str(file_path),
                    line=line_num,
                    code_snippet=loop_content.strip(),
                    recommendation="Add maximum iteration limit or use batch processing"
                ))

    def check_precision_issues(self, file_path: Path, content: str, lines: List[str]):
        """Check for precision-related issues"""

        # Check for consistent precision constants
        precision_constants = re.findall(r'const\s+\w*PRECISION\w*:\s*u64\s*=\s*(\d+)', content)
        if len(set(precision_constants)) > 1:
            self.findings.append(Finding(
                severity=Severity.MEDIUM,
                title="Inconsistent Precision Constants",
                description=f"Multiple precision constants found: {set(precision_constants)}",
                file=str(file_path),
                line=1,
                code_snippet="",
                recommendation="Use a single, consistent precision constant throughout"
            ))

    def generate_report(self) -> str:
        """Generate a formatted security report"""
        if not self.findings:
            return "✅ No security issues found! Great work!"

        # Sort by severity
        severity_order = {
            Severity.CRITICAL: 0,
            Severity.HIGH: 1,
            Severity.MEDIUM: 2,
            Severity.LOW: 3,
            Severity.INFO: 4
        }
        self.findings.sort(key=lambda x: severity_order[x.severity])

        # Count by severity
        counts = {s: 0 for s in Severity}
        for finding in self.findings:
            counts[finding.severity] += 1

        report = "=" * 80 + "\n"
        report += "🛡️  SUI MOVE SECURITY ANALYSIS REPORT\n"
        report += "=" * 80 + "\n\n"

        report += "📊 SUMMARY\n"
        report += "-" * 40 + "\n"
        for severity in Severity:
            if counts[severity] > 0:
                report += f"{severity.value}: {counts[severity]}\n"
        report += f"\nTotal Issues: {len(self.findings)}\n\n"

        report += "=" * 80 + "\n"
        report += "🔍 DETAILED FINDINGS\n"
        report += "=" * 80 + "\n\n"

        for i, finding in enumerate(self.findings, 1):
            report += f"[{i}] {finding.severity.value} - {finding.title}\n"
            report += f"File: {finding.file}:{finding.line}\n"
            report += f"Description: {finding.description}\n"
            if finding.code_snippet:
                report += f"Code: {finding.code_snippet}\n"
            report += f"💡 Recommendation: {finding.recommendation}\n"
            report += "-" * 80 + "\n\n"

        report += "=" * 80 + "\n"
        report += "✨ NEXT STEPS\n"
        report += "=" * 80 + "\n"
        report += "1. Review all CRITICAL and HIGH severity findings immediately\n"
        report += "2. Implement recommended fixes\n"
        report += "3. Add comprehensive test coverage\n"
        report += "4. Consider formal verification for critical functions\n"
        report += "5. Schedule external security audit\n\n"

        return report


def main():
    if len(sys.argv) < 2:
        print("Usage: python analyze_contract.py <path_to_move_sources>")
        print("Example: python analyze_contract.py ../project3-lending-protocol/lending_protocol/sources")
        sys.exit(1)

    source_dir = Path(sys.argv[1])
    if not source_dir.exists():
        print(f"Error: Directory {source_dir} does not exist")
        sys.exit(1)

    analyzer = SuiMoveAnalyzer(source_dir)
    findings = analyzer.analyze()

    print("\n" + analyzer.generate_report())

    # Save report to file
    report_path = Path("security_audit_report.txt")
    with open(report_path, 'w') as f:
        f.write(analyzer.generate_report())

    print(f"📄 Full report saved to: {report_path.absolute()}\n")

    # Exit with error code if critical/high findings
    critical_or_high = sum(1 for f in findings if f.severity in [Severity.CRITICAL, Severity.HIGH])
    if critical_or_high > 0:
        sys.exit(1)
    else:
        sys.exit(0)


if __name__ == "__main__":
    main()
