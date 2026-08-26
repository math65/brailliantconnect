# Notes de version

## v1.1.0 — 26/08/2026

Signaler un problème ne demande plus de Terminal.

La version 1.0.0 avait été construite et éprouvée sur un seul modèle, une
BI 40X, et le disait. Les réponses sont arrivées dans la semaine : quelqu'un l'a
essayée sur un Mantis, le menu annonçait une plage connectée, et le Finder
n'affichait rien. Cette personne n'avait aucun moyen d'en dire plus, ni moi de
le lui demander — le diagnostic vit derrière un outil en ligne de commande que
personne ne devrait avoir à ouvrir.

L'application le produit désormais à sa place.

### Signaler un problème…
- **Un nouvel élément dans la barre des menus** ouvre une fenêtre : vous
  indiquez de quoi il s'agit, écrivez une ligne ou deux, et donnez une adresse
  pour la réponse. Les suggestions et les questions passent par la même fenêtre.
- **La fenêtre répond souvent avant l'envoi.** Une plage branchée mais en veille,
  ou qui ne répond qu'en terminal braille parce que le transfert de fichiers est
  désactivé, l'application le voit d'elle-même : elle le dit, et nomme le remède.
  Elle ne vous empêche jamais d'envoyer malgré tout.
- **Un signalement inclut un diagnostic, et l'annonce avant que vous n'envoyiez :**
  la version de l'application et de macOS, ce que le bus USB dit de la plage, la
  publication ou non de l'emplacement dans le Finder, ainsi que le modèle, le
  numéro de série et les stockages de la plage tels qu'ils ont été lus la
  dernière fois. Rien d'autre ne quitte votre machine.
- **Le diagnostic fonctionne même pendant que le Finder se sert de la plage.**
  Le MTP n'accepte qu'une connexion à la fois : rien ne peut interroger la plage
  tant que le Finder la tient. Ce que voit le Finder en se connectant est noté au
  passage, et le signalement le reprend de là.

### Annonces
- **L'application peut maintenant recevoir un message de son auteur au
  démarrage** — une version à éviter, un micrologiciel qui casse le transfert de
  fichiers. Il n'y a ici ni mécanisme de mise à jour ni compte, et jusqu'à
  présent une personne qui avait installé l'application n'avait plus aucun moyen
  d'en entendre parler.

### Corrections
- **La fenêtre d'accueil décrivait une BI 40X et rien d'autre.** Elle nommait les
  deux dossiers de stockage littéralement — `mémoire interne` et `usb` — alors
  que ces noms viennent de la plage elle-même et changent d'un modèle à l'autre,
  et elle supposait que le support amovible était une clé USB, ce qu'il n'est pas
  sur une plage qui prend une carte microSD.
- **Les textes de l'application ont été repris.** Le menu affichait « MTP
  désactivé sur la plage », en nommant un protocole pour lequel personne ne
  branche une plage ; il indique désormais que le transfert de fichiers est
  désactivé, et pointe vers le réglage.

## v1.0.0 — 20/08/2026

Première version publique.

Une plage braille a une mémoire, et cette mémoire est faite pour qu'on y dépose
des livres et des documents. Sur un Mac, y accéder demandait jusqu'ici de poser
une extension au cœur du système. BrailliantConnect ne pose rien : il se glisse
dans les Applications, on l'ouvre une fois, et la plage se comporte ensuite
comme une clé USB — branchée, elle est là ; débranchée, elle n'y est plus.

L'auteur se sert lui-même d'une Brailliant au lecteur d'écran. Tout ce que
l'application dit est écrit pour être lu au braille : un fait par ligne, jamais
un état signalé par une couleur ou par une icône seule.

### Installation
- **Glissez l'application dans le dossier Applications, puis ouvrez-la une
  fois.** C'est toute l'installation. L'application s'inscrit auprès du système
  pour revenir à chaque ouverture de session, puis se retire : ce qui tourne
  ensuite n'est pas la copie que vous avez double-cliquée.
- **Une fenêtre d'accueil s'ouvre au premier lancement** et nomme les deux ou
  trois choses qui ne se devinent pas — au premier rang, le réglage à activer
  sur la plage elle-même.

### Sur la plage : le MTP
- **Le transfert de fichiers doit être activé sur la plage**, une seule fois, et
  c'est probablement déjà fait : il l'est par défaut depuis la version 2.5 du
  logiciel de la plage. Sinon, sur la plage : Options, Paramètres de l'utilisateur,
  MTP.
- **Rien n'est basculé ni désactivé.** Une plage jointe par le Mac publie ses
  interfaces braille *et* celle du transfert de fichiers en même temps, et reste
  utilisable comme terminal braille pendant toute la durée d'une copie.

### La plage dans le Finder
- **Un dossier « Brailliant » apparaît dans votre dossier de départ** dès que la
  plage est branchée, et disparaît quand vous la retirez.
- **Il contient un dossier par mémoire, jamais de fichier directement.** La
  mémoire interne de la plage en est une ; une clé USB branchée sur la plage en
  est une autre, et elle apparaît à côté plutôt que de rester invisible. Vos
  documents sont donc un niveau plus bas.
- **Rien ne peut être créé à la racine**, puisque cet endroit n'appartient à
  aucune mémoire. Une copie déposée là est refusée, et l'application vous le
  signale plutôt que de laisser un fichier que le Finder montre et que la plage
  n'a jamais reçu.

### Les transferts
- **Le Finder rend la main immédiatement, longtemps avant la fin de la copie.**
  Trois gigaoctets reviennent en une fraction de seconde et continuent de partir
  pendant sept minutes, à environ 7 Mo par seconde.
- **L'application vous dit donc quand il ne faut pas débrancher**, dans la barre
  des menus, et vous prévient quand le transfert est terminé. Sans cela, rien à
  l'écran ne distinguerait une copie finie d'une copie qui vient de commencer.
- **Supprimer, en revanche, est immédiat** — environ treize millisecondes par
  élément, quelle que soit sa taille. Il n'y a là aucune fenêtre pendant
  laquelle débrancher pourrait tronquer quoi que ce soit.

### La barre des menus
- **Un élément dans la barre des menus est la seule partie visible.** Il dit si
  la plage est là, ouvre son dossier, et distingue les cas où elle est branchée
  sans répondre : endormie, ou le MTP éteint — chacun avec le geste qui le
  résout.
- **Quitter arrête vraiment.** L'emplacement est retiré du Finder et l'agent
  s'arrête pour de bon ; rouvrir l'application le ramène aussitôt, et il revient
  de lui-même à la prochaine ouverture de session tant que *Ouvrir à l'ouverture
  de session* reste coché.

### Désinstallation
- **Une entrée du menu retire tout ce que l'application a écrit** — l'emplacement,
  le raccourci, l'agent, les préférences, les conteneurs, les journaux — et place
  l'application dans la corbeille. Rien sur la plage braille n'est touché.

### Ce que cette version ne fait pas
- **Une seule connexion à la fois.** Le protocole n'en autorise pas davantage :
  pendant que le Finder tient la plage, la commande `brailliant` ne peut pas
  l'atteindre, et réciproquement.
- **Ce que vous modifiez depuis la plage elle-même passe inaperçu** jusqu'à ce
  que le dossier soit relu : la plage n'annonce pas ses changements.

### Signaler un problème
- **`brailliant --version` dit quelle version vous avez**, et `brailliant doctor`
  la reprend en tête de son rapport. C'est la première chose à joindre quand
  quelque chose ne va pas : sans elle, un comportement décrit ne se rattache à
  aucune version précise.

### Matériel
Développé et vérifié sur une **Brailliant BI 40X**. Rien dans le code ne dépend
du modèle, mais cela reste à confirmer sur les autres. Si vous en possédez un
autre, `brailliant doctor` et son résultat seraient d'une aide réelle.
