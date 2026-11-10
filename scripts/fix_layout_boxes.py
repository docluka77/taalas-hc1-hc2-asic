#!/usr/bin/env python3
import os
import re

tex_path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "paper", "taalas_hc1_arch_verif.tex")
with open(tex_path, "r", encoding="utf-8") as f:
    s = f.read()

# 1. Add hbadness/vbadness and hyperref pdfstringdefDisableCommands
old_preamble = r"""\emergencystretch=2.5em
\sloppy
\hfuzz=2pt
\vfuzz=2pt"""

new_preamble = r"""\emergencystretch=3em
\sloppy
\hbadness=10000
\vbadness=10000
\hfuzz=2pt
\vfuzz=2pt
\pdfstringdefDisableCommands{%
  \def\texttt#1{#1}%
  \def\textbf#1{#1}%
  \def\to{->}%
  \def\times{x}%
}"""
s = s.replace(old_preamble, new_preamble)

# 2. Wrap all \begin{tabular} ... \end{tabular} in \resizebox{\textwidth}{!}{...}
s = re.sub(
    r"(\\begin\{tabular\}\{[^\n]+\}.*?\\end\{tabular\})",
    r"\\resizebox{\\textwidth}{!}{\1}",
    s,
    flags=re.DOTALL,
)

# 3. Fix the 4 wide equations (eq:n_attn..n_total, eq:csd_sum, eq:nr_recip, eq:compiler_opt)
s = s.replace(
    r"N_{\text{attn/layer}} &= d_{\text{model}}^2 (W_Q) + 2 d_{\text{model}}(H_{KV}d_{\text{head}}) (W_K, W_V) + d_{\text{model}}^2 (W_O) \nonumber\\",
    r"N_{\text{attn/layer}} &= d_{\text{model}}^2 (W_Q, W_O) + 2 d_{\text{model}}H_{KV}d_{\text{head}} \nonumber\\"
)

for eq_label in ["eq:csd_sum", "eq:nr_recip", "eq:compiler_opt"]:
    pattern = r"\\begin\{equation\}\n(.*?)\n\\label\{" + eq_label + r"\}\n\\end\{equation\}"
    def wrap_eq(m):
        body = m.group(1).strip()
        return "\\begin{equation}\n\\resizebox{0.88\\columnwidth}{!}{$\\displaystyle " + body + "$}\n\\label{" + eq_label + "}\n\\end{equation}"
    s = re.sub(pattern, wrap_eq, s, flags=re.DOTALL)

with open(tex_path, "w", encoding="utf-8") as f:
    f.write(s)

print("Updated layout boxes in", tex_path)
