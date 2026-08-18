# Anti-patterns

Les solutions qui viennent naturellement à l'esprit, et pourquoi elles ne tiennent pas.
Chacune a été envisagée puis écartée pendant la conception de ce dépôt.

---

## 1. « Je lui donne mon mot de passe sudo »

**L'idée :** communiquer le mot de passe à l'agent pour qu'il se débrouille.

**Pourquoi c'est faux :**

- Le mot de passe finit **en clair et durablement** dans les transcripts de session, les
  logs et l'historique — bien au-delà du moment où on en avait besoin.
- Il donne un accès root **total**, sans aucune borne.
- Il est réutilisable par quiconque accède à ces traces, longtemps après.
- Aucune révocation possible sans changer le mot de passe du compte humain.

**À la place :** un utilisateur dédié, sans mot de passe du tout, avec `NOPASSWD` sur une
liste fermée de commandes.

---

## 2. « Je mets l'agent dans le groupe `docker` »

**L'idée :** l'agent a besoin de `docker logs`, on l'ajoute au groupe, sans toucher à sudo.

**Pourquoi c'est faux — et c'est l'erreur la plus fréquente :**

Le groupe `docker` **équivaut à un accès root complet**. Le démon Docker tourne en root, et
qui peut lui parler peut lui demander n'importe quoi :

```bash
# Membre du groupe docker, "sans privilèges" :
docker run -v /:/host -it alpine chroot /host sh
# → shell root sur l'hôte.
```

Ce n'est pas une faille, c'est le fonctionnement documenté de Docker. Tout durcissement
sudoers appliqué à côté est purement décoratif.

**À la place :** l'agent n'est pas dans le groupe `docker`. Les wrappers appellent `docker`
en root, et n'exposent que les opérations prévues.

---

## 3. « Je filtre les commandes avec des motifs sudoers »

**L'idée :** encoder les restrictions directement dans sudoers, sans écrire de script.

```
# Ne faites pas ça.
claude ALL=(root) NOPASSWD: /usr/bin/docker logs *
```

**Pourquoi c'est faux :**

Le joker `*` en sudoers est bien plus permissif qu'il n'en a l'air. Il couvre les espaces,
donc des arguments supplémentaires — et `docker logs` n'est qu'un sous-ensemble d'une CLI
qui sait monter des volumes et lancer des conteneurs privilégiés. Les contournements de
motifs sudoers sont un classique documenté.

Plus fondamentalement : **sudoers est un mécanisme d'autorisation, pas un validateur
d'entrées.** Lui demander de faire de l'analyse d'arguments, c'est l'employer hors de son
domaine.

**À la place :** sudoers autorise un chemin absolu ; la validation vit dans le script.

---

## 4. « Un joker sur le nom du binaire, c'est pratique »

```
# Ne faites pas ça.
claude ALL=(root) NOPASSWD: /usr/local/bin/ops-*
```

**Pourquoi c'est faux :**

Le joker porte ici sur le **nom du programme**. Tout fichier créé plus tard dans ce
répertoire devient exécutable en root. Il suffit d'un script déposé par un autre outil, ou
d'un `ops-debug` bricolé un soir, pour ouvrir une escalade complète.

**À la place :** chaque commande est énumérée nominativement. Un joker sur les *arguments*
est acceptable — le script les valide ; un joker sur le *chemin* ne l'est jamais.

---

## 5. « Je dis à l'agent de ne pas toucher à la base »

**L'idée :** une consigne en langage naturel dans le prompt système ou un fichier
d'instructions.

**Pourquoi c'est faux :**

C'est une politesse, pas un contrôle. Elle échoue dans les deux cas qui comptent :

- **L'erreur de bonne foi.** L'agent croit sincèrement agir sur l'application alors qu'il
  vise la base — la consigne ne l'aide pas, il pense la respecter.
- **L'injection de prompt.** Le contenu lu par l'agent (une ligne de log, un fichier) peut
  contenir une instruction contraire. Une consigne ne protège pas contre une menace dont le
  principe est justement de corrompre le jugement de l'agent.

**À la place :** une allowlist lue par le script, en root. Le refus est dans le fichier, pas
dans la bonne volonté de l'agent.

---

## 6. « Le script tourne en root, donc c'est sécurisé »

**L'idée :** puisque le wrapper s'exécute en root et valide ses entrées, l'affaire est
close.

**Pourquoi c'est incomplet :**

Tout repose sur une hypothèse rarement vérifiée : **que le script ne soit pas modifiable par
l'agent**. Si `claude-ops` peut écrire dans `/usr/local/bin/ops-logs`, il réécrit le script
qu'il a le droit de lancer en root. Il n'y a plus aucune sécurité — juste l'illusion d'une.

Même remarque pour le `PATH` : un script root qui appelle `docker` sans `PATH` figé exécute
le `docker` de l'appelant.

**À la place :** `ops_assert_integrity()` vérifie propriétaire et permissions à **chaque**
exécution, et refuse de tourner si l'invariant est rompu.

---

## 7. « Les garde-fous côté client suffisent »

**L'idée :** configurer des hooks ou des règles de permission dans l'outil agent pour
bloquer les commandes dangereuses.

**Pourquoi c'est insuffisant :**

C'est utile — en **défense en profondeur**. Ce n'est pas une frontière de sécurité : ça vit
du même côté que la chose dont on se protège. Un client mal configuré, contourné ou remplacé
laisse tomber la protection, et le serveur n'en sait rien.

**À la place :** la frontière est côté serveur. Les garde-fous client viennent en supplément,
jamais en remplacement.

---

## 8. « Je filtre les secrets en sortie »

**L'idée :** exposer une commande verbeuse — `docker inspect`, `env`, un dump de config —
et nettoyer le résultat avec un filtre de redaction avant de le rendre.

**Pourquoi c'est faux :**

Un filtre de redaction reconnaît des **formes** : un préfixe `sk-`, la structure d'un JWT,
une URI `postgres://user:pass@`. Il ne reconnaît pas un secret — cette notion n'a aucune
existence syntaxique. `INTERNAL_SIGNING_KEY=a7f3c9e21b` est un secret critique et une chaîne
parfaitement banale.

Le déséquilibre est structurel : le filtre doit avoir raison **à chaque fois**, une seule
omission suffit. Et l'échec est silencieux — rien ne signale qu'un secret est passé. On ne
l'apprend pas, on le subit.

`docker inspect` est le cas d'école : sa sortie contient `.Config.Env`, donc l'intégralité
des secrets applicatifs du conteneur. L'exposer en comptant sur un filtre, c'est parier tous
les secrets d'un service sur l'exhaustivité d'une poignée d'expressions régulières.

**À la place :** une liste blanche de champs. `ops-inspect` énumère ce qu'il affiche — état,
healthcheck, réseau, image, montages — et rien d'autre ne peut sortir. Un champ nouveau ou
imprévu est invisible par défaut.

La différence tient en une phrase : **filtrer ce qu'on connaît échoue sur ce qu'on n'a pas
prévu ; n'autoriser que ce qu'on a choisi échoue en refusant.** Le second mode d'échec est le
seul acceptable.

La redaction garde sa place — en dernier filet, sur des sorties déjà restreintes. Jamais
comme frontière.

---

## 9. « `docker exec`, c'est juste du diagnostic »

**L'idée :** l'agent a besoin de regarder à l'intérieur d'un conteneur — les ports en écoute,
un fichier de config, un processus. Un wrapper `ops-exec <service> <commande>`, limité à des
commandes inoffensives, ferait l'affaire.

**Pourquoi c'est faux :**

`docker exec` est de l'**exécution de code arbitraire** dans un conteneur. L'emballer dans un
wrapper « lecture seule » ne change pas sa nature, seulement son nom. Et restreindre la
commande passée ne sauve rien : les binaires réputés inoffensifs sont des langages complets.
`find` exécute (`-exec`), `awk` lance des processus (`system()`), `tar` écrit où on lui dit.

Plus fondamentalement, ça déplace la frontière au mauvais endroit. Le wrapper devrait alors
valider une *commande*, pas un *nom de service* — c'est-à-dire résoudre le problème que
sudoers ne sait déjà pas résoudre (anti-pattern nº 3), une couche plus bas.

**À la place :** demander au noyau, pas au conteneur. Les sockets en écoute d'un conteneur
sont lisibles dans `/proc/<pid>/net/tcp{,6}` depuis l'hôte : le noyau y expose la table TCP
de son namespace réseau. C'est une lecture de fichier, aucun processus n'est lancé de l'autre
côté.

La question utile n'est pas « quelle commande puis-je autoriser ? » mais **« cette
information existe-t-elle quelque part où la lire ne demande pas d'exécuter quoi que ce
soit ? »**. Étonnamment souvent, la réponse est oui.

---

## Les deux tests

Les sept premiers anti-patterns échouent tous à la même question :

> Est-ce que la protection tient encore si l'agent a été **entièrement convaincu** de faire
> le contraire de ce qu'on attend de lui ?

Si la réponse dépend de ce que l'agent *décide*, ce n'est pas de la sécurité.
Si elle dépend de ce que le serveur *permet*, c'en est.

Les nºˢ 8 et 9 passent ce test — et échouent quand même. Un filtre de redaction s'exécute
bien côté serveur ; aucune manipulation de l'agent ne le désactive. Il échoue à une question
différente :

> Quand cette protection se trompe, **est-ce qu'on l'apprend** — et est-ce qu'elle se trompe
> en refusant, ou en laissant passer ?

Une liste blanche qui rate un cas refuse quelque chose de légitime : on le voit, on l'ajoute.
Un filtre qui rate un cas laisse fuiter un secret, sans bruit. Même côté serveur, même
incontournable, ce n'est pas la même chose.

Une règle de ce dépôt doit passer les deux : **ne pas dépendre du jugement de l'agent, et se
tromper du bon côté.**
