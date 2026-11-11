#!/usr/bin/env python3
"""Duel du « système 1 » (vague 3), candidat « encodeur » : EmbeddingGemma 2 compare le passage à chaque sens.

Le passage (avec le terme) et chaque sens candidat deviennent des vecteurs ; le sens le plus proche est le choix. La
confiance est l'écart de similarité ramené entre 0 et 1 (softmax). Tourne dans bench/.venv, sur le GPU du Mac.

On charge seulement la partie texte, avec la chaîne de sentence-transformers refaite à la main (moyenne des vecteurs,
puis normalisation) : son chargement complet exige les paquets image et vidéo, qui imposeraient un autre PyTorch.

Usage : bench/.venv/bin/python scripts/sens-embeddinggemma.py [--cas bench/cas-sens.json] [--temperature 0.02]
"""
import argparse
import time

import torch
from transformers import AutoModel, AutoTokenizer

from sens_commun import load_cases, report, row


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cas", default="bench/cas-sens.json")
    parser.add_argument("--modele", default="google/embeddinggemma-2")
    parser.add_argument("--temperature", type=float, default=0.02)
    args = parser.parse_args()
    cases = load_cases(args.cas)
    tokenizer = AutoTokenizer.from_pretrained(args.modele)
    model = AutoModel.from_pretrained(args.modele).to("mps").eval()

    def embed(texts):
        batch = tokenizer(texts, padding=True, truncation=True, max_length=512, return_tensors="pt").to("mps")
        with torch.no_grad():
            hidden = model(**batch).last_hidden_state
        mask = batch["attention_mask"].unsqueeze(-1).to(hidden.dtype)
        return torch.nn.functional.normalize((hidden * mask).sum(1) / mask.sum(1), dim=-1)

    def choose(case):
        start = time.perf_counter()
        # Les consignes du modèle : « query » pour le passage, « document » pour les sens.
        query = embed([f"task: search result | query: {case['term']} : {case['context']}"])
        senses = embed([f"title: none | text: {s['description']}" for s in case["senses"]])
        similarities = (query @ senses.T)[0]
        probabilities = torch.softmax(similarities / args.temperature, dim=0).tolist()
        return probabilities, (time.perf_counter() - start) * 1000

    choose(cases[0])  # chauffe
    rows = []
    for case in cases:
        probabilities, ms = choose(case)
        choice = max(range(len(probabilities)), key=probabilities.__getitem__)
        rows.append(row(case, choice, probabilities[choice], ms))
        print(f"{case['id']} {'✓' if choice == case['answer'] else '✗'} {probabilities[choice]:.2f} · {ms:.0f} ms")
    report("embeddinggemma", rows, model=args.modele, temperature=args.temperature)


if __name__ == "__main__":
    main()
