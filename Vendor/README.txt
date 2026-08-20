Bibliothèques tierces embarquées par BrailliantConnect
======================================================

  libusb 1.0.30   — https://libusb.info/
  libmtp 1.1.23   — https://libmtp.sourceforge.net/

Toutes deux sont distribuées sous licence GNU LGPL version 2.1 ou ultérieure.
Le texte des licences se trouve dans LICENSE-libusb.txt et LICENSE-libmtp.txt.

Conformément à la LGPL, ces bibliothèques sont liées DYNAMIQUEMENT : elles sont
chargées à l'exécution par l'éditeur de liens du système et peuvent être
remplacées par une autre version compatible en substituant simplement les
fichiers .dylib — dans ce dossier pour la commande, dans Contents/Frameworks
pour l'application.

Elles ont été compilées sans modification du code source amont, par le script
tools/build-vendor.sh fourni avec ce projet, qui permet de les reconstruire.
