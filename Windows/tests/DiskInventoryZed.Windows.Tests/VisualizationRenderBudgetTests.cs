using DiskInventoryZed.Windows.Controls;

namespace DiskInventoryZed.Windows.Tests;

public sealed class VisualizationRenderBudgetTests
{
    [Fact]
    public void ViewportBudgetsScaleAndStayBounded()
    {
        Assert.Equal(VisualizationRenderBudget.Minimum, VisualizationRenderBudget.ForTreemap(1, 1));
        Assert.Equal(VisualizationRenderBudget.Minimum, VisualizationRenderBudget.ForSunburst(1, 1));
        Assert.InRange(
            VisualizationRenderBudget.ForTreemap(800, 600),
            VisualizationRenderBudget.Minimum,
            VisualizationRenderBudget.Maximum);
        Assert.Equal(VisualizationRenderBudget.Maximum, VisualizationRenderBudget.ForTreemap(8000, 8000));
        Assert.Equal(VisualizationRenderBudget.Maximum, VisualizationRenderBudget.ForSunburst(4000, 7));
    }
}
