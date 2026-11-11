#!/usr/bin/env python3
"""Duel du « système 1 » (vague 3), candidat « modèle contraint » : Gemma 4 E4B choisit le sens en un seul jeton.

Le prompt liste les sens candidats numérotés. On lit la probabilité de chaque numéro au premier jeton de la réponse :
le plus probable est le choix, sa probabilité la confiance. Rien n'est écrit : le temps est celui de la lecture du
prompt, sans le cache des consignes de l'app.

Usage : python3 scripts/sens-gemma.py [--cas bench/cas-sens.json] [--modele mlx-community/gemma-4-e4b-it-4bit]
"""
import argparse
import time

import mlx.core as mx
from mlx_lm import load

from sens_commun import load_cases, report, row


def prompt(case):
    options = "\n".join(f"{i + 1}. {sense['description']}" for i, sense in enumerate(case["senses"]))
    return (f"Passage : « {case['context']} »\nTerme : « {case['term']} »\nSens possibles :\n{options}\n\n"
            "Quel est le sens du terme dans ce passage ? Réponds seulement par le numéro.")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cas", default="bench/cas-sens.json")
    parser.add_argument("--modele", default="mlx-community/gemma-4-e4b-it-4bit")
    # Certains modèles (Ministral 3) ajoutent une longue consigne par défaut quand il n'y en a pas : une courte la remplace.
    parser.add_argument("--consigne", default=None)
    args = parser.parse_args()
    cases = load_cases(args.cas)
    model, tokenizer = load(args.modele)
    digits = [tokenizer.encode(str(i), add_special_tokens=False) for i in range(1, 10)]
    assert all(len(d) == 1 for d in digits), "chaque numéro doit tenir en un jeton"
    digits = [d[0] for d in digits]

    def choose(case):
        messages = [{"role": "system", "content": args.consigne}] if args.consigne else []
        text = tokenizer.apply_chat_template(
            messages + [{"role": "user", "content": prompt(case)}], add_generation_prompt=True, tokenize=False,
            enable_thinking=False)
        tokens = tokenizer.encode(text, add_special_tokens=False)
        start = time.perf_counter()
        logits = model(mx.array([tokens]))[0, -1]
        probabilities = mx.softmax(logits[mx.array(digits[:len(case["senses"])])].astype(mx.float32))
        mx.eval(probabilities)
        return probabilities.tolist(), (time.perf_counter() - start) * 1000, len(tokens)

    choose(cases[0])  # chauffe : compilation des noyaux Metal
    rows = []
    for case in cases:
        probabilities, ms, length = choose(case)
        choice = max(range(len(probabilities)), key=probabilities.__getitem__)
        rows.append(row(case, choice, probabilities[choice], ms, tokens=length))
        print(f"{case['id']} {'✓' if choice == case['answer'] else '✗'} {probabilities[choice]:.2f} · {ms:.0f} ms")
    report("gemma", rows, model=args.modele, instruction=args.consigne)


if __name__ == "__main__":
    main()
