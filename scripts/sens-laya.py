#!/usr/bin/env python3
"""Duel du « système 1 » (vague 3), candidat « modèle de décision » : Laya multilingue choisit le sens en une passe.

Laya lit le passage et le terme, puis répond à une question à choix dont chaque option est un sens candidat ; il donne
la probabilité de chaque option. Tourne dans l'environnement du banc (bench/.venv), sur le GPU du Mac.

Usage : USE_TF=0 bench/.venv/bin/python scripts/sens-laya.py [--cas bench/cas-sens.json]
"""
import argparse
import time

import laya

from sens_commun import load_cases, report, row


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cas", default="bench/cas-sens.json")
    parser.add_argument("--modele", default="convaiinnovations/laya-multilingual")
    args = parser.parse_args()
    cases = load_cases(args.cas)
    agent = laya.load(args.modele, device="mps")

    def choose(case):
        labels = [f"{i + 1}. {sense['title']}"[:60] for i, sense in enumerate(case["senses"])]
        question = {"meaning": {
            "type": "choice",
            "instructions": "Which meaning does the word `term` have in `passage`?",
            "criteria": {label: sense["description"] for label, sense in zip(labels, case["senses"])},
        }}
        start = time.perf_counter()
        answer = agent.predict({"passage": case["context"], "term": case["term"]}, question)["answers"]["meaning"]
        ms = (time.perf_counter() - start) * 1000
        return labels.index(answer["choice"]), answer, ms

    choose(cases[0])  # chauffe
    rows = []
    for case in cases:
        choice, answer, ms = choose(case)
        # La probabilité de l'option choisie (« confidence » est une autre mesure, plus basse).
        confidence = answer["answer_confidence"]
        rows.append(row(case, choice, float(confidence), ms))
        print(f"{case['id']} {'✓' if choice == case['answer'] else '✗'} {float(confidence):.2f} · {ms:.0f} ms")
    report("laya", rows, model=args.modele)


if __name__ == "__main__":
    main()
