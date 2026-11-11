#!/usr/bin/env python3
"""Fabrique des cas du banc d'essai à partir de Wikipédia, sans intervention.

Pour chaque langue, on part d'articles de thèmes variés (économie, santé, informatique, droit, sciences…).
Dans leur introduction, chaque lien interne donne un cas : le terme est le texte du lien, le contexte sa phrase,
et le sens attendu la première phrase de l'article visé. Le lien désigne déjà le bon sens : « noyau » mène à
« Noyau (informatique) » ou à « Noyau atomique » selon la phrase. On garde en priorité ces termes à plusieurs sens.

Usage : python3 scripts/cas-wikipedia.py [--par-langue 10] [--sortie bench/cas-wikipedia.json]
Les textes viennent de Wikipédia, sous licence CC BY-SA 4.0 : chaque cas garde sa source.
"""
import argparse
import html
import json
import re
import ssl
import time
import urllib.parse
import urllib.request

import certifi

CONTEXT = ssl.create_default_context(cafile=certifi.where())
AGENT = "HoovaBench/0.1 (https://github.com/Teay2026/hoova)"
LANGUAGES = ["en", "es", "fr", "de", "pt", "it", "zh", "ja"]
# Articles de départ, en anglais ; on les retrouve dans chaque langue par les liens entre langues.
SEEDS = [
    "Inflation", "Interest rate", "Operating system", "Monoclonal antibody", "Employment contract",
    "Machine learning", "Vaccine", "Photosynthesis", "Stock market", "Climate change", "Central bank",
    "Encryption", "Antibiotic", "Supply chain", "Mortgage loan", "Leverage (finance)", "Atomic nucleus",
    "Contract", "Immune system", "Compiler",
]

TAG = re.compile(r"<[^>]+>")
REFERENCE = re.compile(r"<sup[^>]*>.*?</sup>", re.S)
PARAGRAPH = re.compile(r"<p>(.*?)</p>", re.S)
LINK = re.compile(r'<a href="/wiki/([^"#]+)"[^>]*?title="([^"]+)"[^>]*>(.*?)</a>', re.S)
SENTENCE_END = re.compile(r"(?<=[.!?])\s+|(?<=[。！？])")


def get(url, **params):
    if params:
        url += "?" + urllib.parse.urlencode(params)
    request = urllib.request.Request(url, headers={"User-Agent": AGENT})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(request, context=CONTEXT, timeout=20) as response:
                return json.load(response)
        except Exception:
            if attempt == 2:
                return None
            time.sleep(1 + attempt)


def api(language, **params):
    return get(f"https://{language}.wikipedia.org/w/api.php", format="json", formatversion=2, **params)


def summary(language, title):
    """Le résumé d'un article : son type (article ou page d'homonymie) et sa première phrase."""
    return get(f"https://{language}.wikipedia.org/api/rest_v1/page/summary/"
               + urllib.parse.quote(title.replace(" ", "_"), safe=""))


def title_in(language, english_title):
    if language == "en":
        return english_title
    data = api("en", action="query", prop="langlinks", titles=english_title, lllang=language, redirects=1)
    pages = (data or {}).get("query", {}).get("pages", [])
    links = pages[0].get("langlinks") if pages else None
    return links[0]["title"] if links else None


def plain(fragment):
    return re.sub(r"\s+", " ", html.unescape(TAG.sub("", REFERENCE.sub("", fragment)))).strip()


def first_sentence(text, limit=300):
    sentence = SENTENCE_END.split(text.strip(), maxsplit=1)[0]
    return sentence[:limit]


def sentence_with(paragraph, term):
    """La phrase qui contient le terme, avec la précédente si elle est courte : c'est le contexte du cas."""
    sentences = [s for s in SENTENCE_END.split(paragraph) if s.strip()]
    for index, sentence in enumerate(sentences):
        if term in sentence:
            if len(sentence) < 80 and index > 0:
                sentence = sentences[index - 1] + " " + sentence
            return sentence.strip()[:400]
    return None


def candidates(language, page_title):
    """Les termes liés de l'introduction d'un article, avec leur phrase et l'article visé."""
    # En chinois et en japonais, la plupart des mots tiennent en deux caractères.
    shortest = 2 if language in ("zh", "ja") else 3
    data = api(language, action="parse", page=page_title, prop="text", section=0, redirects=1,
               disablelimitreport=1, disableeditsection=1)
    if not data or "parse" not in data:
        return []
    found = []
    for raw in PARAGRAPH.findall(data["parse"]["text"])[:3]:
        paragraph = plain(raw)
        if len(paragraph) < 80:
            continue
        for match in LINK.finditer(REFERENCE.sub("", raw)):
            href, target, term = match.group(1), html.unescape(match.group(2)), plain(match.group(3))
            if ":" in urllib.parse.unquote(href) or len(term) < shortest or any(c.isdigit() for c in term):
                continue
            # Sans majuscule (sauf en allemand, où tous les noms en prennent une) : on évite surtout les noms propres.
            if language not in ("de", "zh", "ja") and term[0].isupper():
                continue
            context = sentence_with(paragraph, term)
            if context:
                found.append({"term": term, "target": target, "context": context, "title": page_title})
    return found


def build(language, per_language):
    cases, seen = [], set()
    for seed in SEEDS:
        if len([c for c in cases if c["difficulty"] == "plusieurs sens"]) >= per_language // 2 \
                and len(cases) >= per_language:
            break
        page_title = title_in(language, seed)
        if not page_title:
            continue
        taken = 0
        for found in candidates(language, page_title):
            key = found["term"].lower()
            if key in seen or taken >= 2:
                continue
            target = summary(language, found["target"])
            if not target or target.get("type") != "standard" or not target.get("extract"):
                continue
            seen.add(key)
            taken += 1
            # Plusieurs sens : le titre visé est précisé entre parenthèses, ou le mot seul mène à une page d'homonymie.
            plain_word = summary(language, found["term"])
            several = "(" in found["target"] or (plain_word or {}).get("type") == "disambiguation"
            cases.append({
                "id": f"wiki-{language}-{len(cases) + 1:02d}",
                "source": f"wikipedia:{language}:{page_title}",
                "term": found["term"],
                "context": found["context"],
                "title": page_title,
                "textLanguage": language,
                "readerLanguage": "fr",
                "expected": first_sentence(target["extract"]),
                "expectedSource": f"wikipedia:{language}:{found['target']}",
                "difficulty": "plusieurs sens" if several else "terme lié",
            })
    # Les termes à plusieurs sens d'abord, puis les autres, jusqu'au nombre voulu.
    cases.sort(key=lambda c: c["difficulty"] != "plusieurs sens")
    return cases[:per_language]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--par-langue", type=int, default=10)
    parser.add_argument("--sortie", default="bench/cas-wikipedia.json")
    args = parser.parse_args()
    everything = []
    for language in LANGUAGES:
        cases = build(language, args.par_langue)
        several = sum(c["difficulty"] == "plusieurs sens" for c in cases)
        print(f"{language} : {len(cases)} cas, dont {several} à plusieurs sens")
        everything += cases
    with open(args.sortie, "w", encoding="utf-8") as file:
        json.dump(everything, file, ensure_ascii=False, indent=2)
    print(f"{len(everything)} cas → {args.sortie}")


if __name__ == "__main__":
    main()
