#!/usr/bin/env python3
import os
import re

tex_path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "paper", "taalas_hc1_arch_verif.tex")
with open(tex_path, "r", encoding="utf-8") as f:
    s = f.read()

s = s.replace("Rank-16 LoRA & GQA", r"Rank-16 LoRA \& GQA")

def repl(m):
    t = m.group(1)
    t = t.replace("{", r"\{").replace("}", r"\}")
    t = t.replace("_", r"\_").replace("&", r"\&").replace("%", r"\%").replace("#", r"\#")
    return r"\texttt{" + t + "}"

s = re.sub(r"(?<!`)`([^`'\n]+)`(?!`)", repl, s)

with open(tex_path, "w", encoding="utf-8") as f:
    f.write(s)

print("Sanitized", tex_path)
