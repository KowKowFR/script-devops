"""Paquet `worker` : tout ce qui tourne côté worker RQ (exécution de l'engine,
diffusion des logs). Séparé de `panel.api` pour que le web et le worker restent
deux process indépendants qui ne partagent que la base et Redis.
"""
