#!/usr/bin/env python3
"""Fabrique des cas « choisir le sens » à partir de Wikipédia, sans intervention.

Mêmes articles de départ que scripts/cas-wikipedia.py. On garde les termes liés dont le mot seul a une page
d'homonymie : ses entrées sont les sens candidats, chacune avec sa ligne de description, et le bon sens est l'article
visé par le lien. Sert au duel du « système 1 » (vague 3 de docs/plan.md) : choisir le sens parmi des candidats,
comme on le fera avec les sens du Wiktionnaire.

Usage : python3 scripts/cas-sens.py [--par-langue 15] [--sortie bench/cas-sens.json]
Les textes viennent de Wikipédia, sous licence CC BY-SA 4.0 : chaque cas garde sa source.
"""
import argparse
import hashlib
import html
import importlib.util
import json
import random
import re
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

# Les outils de scripts/cas-wikipedia.py : requêtes, articles de départ, termes liés et leur phrase.
spec = importlib.util.spec_from_file_location("wiki", Path(__file__).with_name("cas-wikipedia.py"))
wiki = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wiki)

# Le suffixe des pages d'homonymie, quand le mot seul mène à un article.
DISAMBIGUATION = {
    "en": "disambiguation", "es": "desambiguación", "fr": "homonymie", "de": "Begriffsklärung",
    "pt": "desambiguação", "it": "disambigua", "zh": "消歧义", "ja": "曖昧さ回避",
}
# Des articles de départ en plus de ceux de cas-wikipedia.py, pour trouver assez de termes ambigus dans chaque langue.
MORE_SEEDS = [
    "Bank", "Cell (biology)", "Computer network", "Electric current", "Bond (finance)", "Court", "Protein",
    "Gene", "Algorithm", "Database", "Internet", "Democracy", "Constitution", "Agriculture", "Energy",
    "Electricity", "Water", "Music", "Painting", "Association football", "Cooking", "Bread", "Wine", "Coffee",
    "Tax", "Insurance", "Memory", "Plant", "Language", "Mathematics",
]
ITEM = re.compile(r"<li>(.*?)</li>", re.S)
FIRST_LINK = re.compile(r'^\s*(?:<[^a][^>]*>\s*)*<a href="/wiki/([^"#]+)"[^>]*?title="([^"]+)"', re.S)
MAX_SENSES = 8


def disambiguation_pages(language, terms):
    """La page d'homonymie de chaque terme qui en a une (le mot seul, ou « mot (homonymie) »), par lots de 50."""
    asked = {}
    for term in terms:
        asked.setdefault(term, term)
        asked.setdefault(f"{term} ({DISAMBIGUATION[language]})", term)
    titles, found = list(asked), {}
    for start in range(0, len(titles), 50):
        batch = titles[start:start + 50]
        data = wiki.api(language, action="query", titles="|".join(batch), prop="pageprops",
                        ppprop="disambiguation", redirects=1, converttitles=1) or {}
        query = data.get("query", {})
        renamed = {item["from"]: item["to"] for item in query.get("normalized", []) + query.get("redirects", [])}
        pages = {page["title"]: page for page in query.get("pages", [])}
        for title in batch:
            target = title
            while target in renamed:
                target = renamed[target]
            if "disambiguation" in pages.get(target, {}).get("pageprops", {}):
                found.setdefault(asked[title], target)
    return found


def senses(language, page_title):
    """Les entrées de la page d'homonymie : l'article de chaque ligne, et la ligne elle-même comme description."""
    data = wiki.api(language, action="parse", page=page_title, prop="text", redirects=1,
                    disablelimitreport=1, disableeditsection=1)
    if not data or "parse" not in data:
        return []
    found, seen = [], set()
    for raw in ITEM.findall(data["parse"]["text"]):
        match = FIRST_LINK.match(raw)
        if not match or ":" in match.group(1):
            continue
        title = html.unescape(match.group(2))
        description = wiki.plain(raw)[:200]
        if title not in seen and len(description) > len(title):
            seen.add(title)
            found.append({"title": title, "description": description})
    return found


def short_description(language, title):
    """La description courte d'un article (celle de Wikidata), par exemple « langue germanique »."""
    data = wiki.api(language, action="query", titles=title, prop="description", redirects=1, converttitles=1) or {}
    pages = data.get("query", {}).get("pages", [])
    return pages[0].get("description") if pages else None


def canonical(language, titles):
    """Le titre de chaque page après ses redirections, pour comparer le lien du cas et les entrées."""
    mapping = {}
    for start in range(0, len(titles), 50):
        batch = titles[start:start + 50]
        data = wiki.api(language, action="query", titles="|".join(batch), redirects=1, converttitles=1) or {}
        query = data.get("query", {})
        renamed = {item["from"]: item["to"] for item in query.get("normalized", []) + query.get("redirects", [])}
        for title in batch:
            target = title
            while target in renamed:
                target = renamed[target]
            mapping[title] = target
    return mapping


def build(language, per_language):
    cases, seen = [], set()
    for seed in wiki.SEEDS + MORE_SEEDS:
        if len(cases) >= per_language:
            break
        page_title = wiki.title_in(language, seed)
        if not page_title:
            continue
        links = [f for f in wiki.candidates(language, page_title) if f["term"].lower() not in seen]
        pages = disambiguation_pages(language, [f["term"] for f in links])
        for found in links:
            key = found["term"].lower()
            if key in seen or found["term"] not in pages or len(cases) >= per_language:
                continue
            seen.add(key)
            page = pages[found["term"]]
            options = senses(language, page)
            if len(options) < 3:
                continue
            names = canonical(language, [found["target"]] + [o["title"] for o in options])
            gold = names[found["target"]]
            answer = next((i for i, o in enumerate(options) if names[o["title"]] == gold), None)
            if answer is None:
                # Souvent en français, la page d'homonymie ne répète pas le sens principal : on l'ajoute, décrit comme
                # les autres entrées (son titre, puis sa description courte).
                description = short_description(language, gold)
                if not description:
                    continue
                options.append({"title": gold, "description": f"{gold}, {description}"})
                answer = len(options) - 1
            # Le bon sens et les premiers autres (souvent les plus courants), dans un ordre mélangé mais fixe.
            kept = [options[answer]] + [o for i, o in enumerate(options) if i != answer][:MAX_SENSES - 1]
            seed_value = int(hashlib.sha256(f"{language}:{found['term']}".encode()).hexdigest(), 16)
            random.Random(seed_value).shuffle(kept)
            cases.append({
                "id": f"sens-{language}-{len(cases) + 1:02d}",
                "source": f"wikipedia:{language}:{page_title}",
                "term": found["term"],
                "context": found["context"],
                "title": page_title,
                "textLanguage": language,
                "senses": kept,
                "answer": kept.index(options[answer]),
                "senseSource": f"wikipedia:{language}:{page}",
            })
        print(f"  {language} · {seed} : {len(cases)} cas", flush=True)
    return cases


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--par-langue", type=int, default=15)
    parser.add_argument("--sortie", default="bench/cas-sens.json")
    args = parser.parse_args()
    with ThreadPoolExecutor(max_workers=len(wiki.LANGUAGES)) as pool:
        results = list(pool.map(lambda language: build(language, args.par_langue), wiki.LANGUAGES))
    everything = []
    for language, cases in zip(wiki.LANGUAGES, results):
        average = sum(len(c["senses"]) for c in cases) / max(len(cases), 1)
        print(f"{language} : {len(cases)} cas, {average:.1f} sens candidats en moyenne")
        everything += cases
    with open(args.sortie, "w", encoding="utf-8") as file:
        json.dump(everything, file, ensure_ascii=False, indent=2)
    print(f"{len(everything)} cas → {args.sortie}")


if __name__ == "__main__":
    main()
