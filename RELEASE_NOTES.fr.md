# Notes de version

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
