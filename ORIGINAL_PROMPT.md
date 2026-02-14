I want to build a triangle based terrain plugin (roblox-polymap). That is basically, a heightmap. Where the triangles forming the hieghtmap are made out of PartType = Wedge. Here's some of the pieces we will need:
* The overall architecture and triangle fill math from GapFill
* The drag handles from Redupe

The key difficulty of building this plugin is that the triangles are _implicit_. I don't want there to be some storage for
specific vertices, just the parts that exist in the workspace. Instead, if you click on a part in the workspace, and it's a think wedgepart / has PartType = Wedge, and is thin, and possibly has an adjacent coplanar part, we can assume the or or two parts are part of a triangle being edited. This could be done with geometry queries like workspace:GetPartBoundsInBox.

Features:
* Click in the viewport to potentially select a vertex of a triangle
* Click and drag in the viewport to marquee select multiple vertices
* Move handles show up letting you move the selected vertices
* Can toggle over to rotate handles as well.
* Can also add new vertices, clicking a vertex to start on and going from there somehow.
* Can add a standard box grid of vertices (grid of square quads, split diagonally into two triangles each)
* Can also add a standard triangular grid of vertices (grid of equilateral triangles)
* Have a way to delete vertices.
* Some way to switch between these functions.
* Some way to paint color onto the terrain.
* Some kind of option when moving verticies with the move tool to have an additional region of influence beyond just the selected vertices with a choice of falloff curves.

Try to complete as much of this as possible. There's a lot of interesting behavior to cover here so write exhaustive tests testing the functionality as you go.