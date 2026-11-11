"""Ce que partagent les candidats du duel du « système 1 » (vague 3 de docs/plan.md) : les cas et le rapport.

Chaque candidat choisit un sens par cas, avec une confiance entre 0 et 1, et note son temps. Le rapport donne la part
de bons sens, le temps (médiane et pire cas courant) et la fiabilité de la confiance, puis s'enregistre dans
bench/resultats/.
"""
import json
import statistics
from datetime import datetime
from pathlib import Path


def load_cases(path="bench/cas-sens.json"):
    return json.load(open(path, encoding="utf-8"))


def row(case, choice, confidence, ms, **extra):
    return {"id": case["id"], "language": case["textLanguage"], "senses": len(case["senses"]), "choice": choice,
            "answer": case["answer"], "correct": choice == case["answer"], "confidence": confidence, "ms": ms,
            **extra}


def report(name, rows, **details):
    def accuracy(selection):
        return round(sum(r["correct"] for r in selection) / len(selection), 3) if selection else None

    def band(low, high):
        selection = [r for r in rows if low <= r["confidence"] < high]
        return {"share": round(len(selection) / len(rows), 3), "accuracy": accuracy(selection)}

    times = sorted(r["ms"] for r in rows)
    summary = {
        "candidate": name, **details, "cases": len(rows), "accuracy": accuracy(rows),
        "chance": round(statistics.mean(1 / r["senses"] for r in rows), 3),
        "medianMs": round(statistics.median(times), 1), "p95Ms": round(times[int(0.95 * (len(times) - 1))], 1),
        # La confiance est fiable si les réponses sûres sont presque toujours justes, et les autres moins souvent.
        "confidence": {"≥ 0,9": band(0.9, 1.01), "0,6 à 0,9": band(0.6, 0.9), "< 0,6": band(0, 0.6)},
        "byLanguage": {language: accuracy([r for r in rows if r["language"] == language])
                       for language in sorted({r["language"] for r in rows})},
    }
    print(json.dumps(summary, ensure_ascii=False, indent=1))
    out = Path("bench/resultats") / f"sens-{name}-{datetime.now():%Y-%m-%d-%H%M}.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps({"summary": summary, "rows": rows}, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"→ {out}")
    return summary
