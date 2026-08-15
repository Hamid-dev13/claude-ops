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

## Le test commun

Chacun de ces anti-patterns échoue à la même question :

> Est-ce que la protection tient encore si l'agent a été **entièrement convaincu** de faire
> le contraire de ce qu'on attend de lui ?

Si la réponse dépend de ce que l'agent *décide*, ce n'est pas de la sécurité.
Si elle dépend de ce que le serveur *permet*, c'en est.
