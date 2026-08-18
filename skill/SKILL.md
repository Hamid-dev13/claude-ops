---
name: vps-ops
description: Diagnostiquer un serveur distant via les wrappers claude-ops (ops-status, ops-logs, ops-inspect). À utiliser pour tout état serveur, conteneur en panne, log applicatif ou incident de production. Ne jamais contourner un refus de ces commandes.
---

# Diagnostic du serveur via claude-ops

Le serveur est accessible par un compte SSH **volontairement limité**. Ce compte ne peut
exécuter que trois commandes, en lecture seule. Il n'a ni accès docker direct, ni shell root,
ni droit d'écriture.

Alias SSH : `ops-server` — **à remplacer par l'alias réel défini dans `~/.ssh/config`.**

## Commandes disponibles

```bash
ssh ops-server 'sudo ops-status'                    # état global : conteneurs, disque, mémoire, charge
ssh ops-server 'sudo ops-logs <service> [lignes]'   # logs d'un conteneur (1-2000, défaut 100)
ssh ops-server 'sudo ops-inspect <service>'         # état, healthcheck, réseau, sockets, montages
```

`<service>` doit figurer dans l'allowlist du serveur. `ops-status` la contourne par nature :
il liste tous les conteneurs, sans jamais lire leur contenu.

## Face à un refus

C'est la règle la plus importante de ce document.

```
ops: service non autorisé : coolify-db
```

Un refus est une **information de conception**, pas un obstacle technique. Il signifie que ce
service a été délibérément écarté — le plus souvent parce que ses logs contiennent des
identifiants, des jetons ou des données personnelles.

**À faire :** rapporter le refus, expliquer ce qu'on cherchait, et proposer un autre angle.

**À ne jamais faire :**

- se rabattre sur un compte SSH plus privilégié pour obtenir le même résultat ;
- suggérer d'ajouter le service à l'allowlist « juste pour ce diagnostic » ;
- chercher un chemin détourné (un autre conteneur qui monterait le même volume, un binaire
  équivalent, une commande qui produirait la même sortie).

Contourner la limite, c'est supprimer la seule chose qui la rend utile. Si l'accès manque
vraiment, cela se décide hors incident, en modifiant l'allowlist ou en ajoutant un wrapper —
avec le raisonnement de sécurité qui va avec.

## Méthode de diagnostic

1. **`ops-status` d'abord.** Vue d'ensemble, aucun argument, aucun risque de se tromper de
   cible.
2. **`ops-inspect` ensuite** si un conteneur est suspect. Il donne l'état, le healthcheck
   avec son nombre d'échecs consécutifs, et les sockets réellement en écoute.
3. **`ops-logs` en dernier.** Les logs sont le réflexe naturel et souvent le plus trompeur :
   une application saine y écrit des erreurs, une application cassée peut n'y rien écrire.

### Trois pièges de lecture

**Corrélation temporelle.** Une erreur dans les logs n'explique un incident que si sa
fréquence colle. Des erreurs espacées de plusieurs jours n'expliquent pas un état dégradé
permanent.

**Le compteur d'échecs consécutifs.** Rapporté à l'intervalle du healthcheck, il date le début
réel du problème. S'il couvre toute la durée de vie du conteneur, la sonde n'a jamais
fonctionné : ce n'est pas une panne, c'est une erreur de configuration d'origine.

**`unhealthy` ≠ en panne.** Le healthcheck peut être faux. Vérifier ce que la sonde
interroge, puis ce que le service écoute réellement — un service lié à `0.0.0.0` n'écoute
qu'en IPv4, et une sonde visant `localhost` peut résoudre en `::1` et échouer alors que tout
va bien.

## Les secrets

Les sorties passent par un filtre de redaction, et `ops-inspect` n'expose qu'une liste
blanche de champs — les variables d'environnement ne sortent jamais du serveur.

Ce filtre attrape les formes courantes, pas un secret arbitraire. **Ne jamais recopier une
sortie brute dans un ticket, un message ou un rapport sans l'avoir relue.**

## Portée de ce document

Ces consignes sont une **aide**, pas une sécurité.

Elles vivent du côté client, c'est-à-dire du même côté que ce dont on se protège. Un agent
manipulé — par une ligne de log formulée comme une instruction, par exemple — les ignorerait
sans difficulté.

La véritable frontière est côté serveur : les wrappers valident en root, l'allowlist refuse
d'elle-même, et rien de ce qui est écrit ici ne peut l'assouplir. Ce document sert à éviter
les erreurs de bonne foi et les tentatives de contournement bien intentionnées. Il ne sert à
rien d'autre, et ne doit pas être présenté autrement.

Voir `docs/threat-model.md` et `docs/anti-patterns.md` (nº 7) pour le raisonnement complet.
