import requests

# Deploy service : serve run text_summarizer:deployment

text = """This article is about the bird. For the band, see Emperor Penguin (band).
Emperor penguin
Adults with a chick on Snow Hill Island, Antarctic Peninsula
Conservation status
Endangered
Endangered (IUCN 3.1)[1]
Scientific classification Edit this classification
Kingdom: 	Animalia
Phylum: 	Chordata
Class: 	Aves
Order: 	Sphenisciformes
Family: 	Spheniscidae
Genus: 	Aptenodytes
Species: 	A. forsteri
Binomial name
Aptenodytes forsteri
Gray, 1844

The emperor penguin (Aptenodytes forsteri) is the tallest and heaviest of all living penguin species and is endemic to Antarctica. The male and female are similar in plumage and size, reaching 100 cm (39 in) in length and weighing from 22 to 45 kg (49 to 99 lb). Feathers of the head and back are black and sharply delineated from the white belly, pale-yellow breast and bright-yellow ear patches.

Like all species of penguin, the emperor is flightless, with a streamlined body, and wings stiffened and flattened into flippers for a marine habitat. Its diet consists primarily of fish, but also includes crustaceans, such as krill, and cephalopods, such as squid. While hunting, the species can remain submerged around 20 minutes, diving to a depth of 535 m (1,755 ft). It has several adaptations to facilitate this, including an unusually structured haemoglobin to allow it to function at low oxygen levels, solid bones that reduce barotrauma, and the ability to reduce its metabolism and shut down non-essential organ functions.

The only penguin species that breeds during the Antarctic winter, emperor penguins trek 50-120 km (31-75 mi) over the ice to breeding colonies which can contain up to several thousand individuals. The female lays a single egg, which is incubated for just over two months by the male while the female returns to the sea to feed; parents subsequently take turns foraging at sea and caring for their chick in the colony. The lifespan of an emperor penguin is typically 20 years in the wild, although observations suggest that some individuals may live as long as 50 years of age.
Taxonomy

Emperor penguins were described in 1844 by English zoologist George Robert Gray, who created the generic name from Ancient Greek word elements, ἀ-πτηνο-δύτης [a-ptēno-dytēs], "without-wings-diver". Its specific name is in honour of the German naturalist Johann Reinhold Forster, who accompanied Captain James Cook on his second voyage and officially named five other penguin species.[2] Forster may have been the first person to see emperor penguins in 1773-74, when he recorded a sighting of what he believed was the similar king penguin (A. patagonicus) but, given the location, may very well have been the emperor penguin (A. forsteri).[3]

Together with the king penguin, the emperor penguin is one of two extant species in the genus Aptenodytes. Fossil evidence of a third species—Ridgen's penguin (A. ridgeni)—has been found from the late Pliocene, about three million years ago, in New Zealand.[4] Studies of penguin behaviour and genetics have proposed that the genus Aptenodytes is basal; in other words, that it split off from a branch which led to all other living penguin species.[5] Mitochondrial and nuclear DNA evidence suggests this split occurred around 40 million years ago.[6]
Description
Adults with chicks

"""
#print(f"-{text}-END")
res = requests.get("http://k8s-raygroup-fa3bac2354-1884733651.ap-southeast-2.elb.amazonaws.com:8000/summarize", params={"text": text})
print(res)
print(res.json())
