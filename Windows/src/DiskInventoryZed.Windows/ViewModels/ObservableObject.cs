using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace DiskInventoryZed.Windows.ViewModels;

public abstract class ObservableObject : INotifyPropertyChanged
{
    private readonly object _notificationGate = new();
    private bool _notificationsEnabled = true;

    public event PropertyChangedEventHandler? PropertyChanged;

    protected bool SetProperty<T>(ref T field, T value, [CallerMemberName] string? propertyName = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value))
        {
            return false;
        }

        field = value;
        OnPropertyChanged(propertyName);
        return true;
    }

    protected void OnPropertyChanged([CallerMemberName] string? propertyName = null)
    {
        lock (_notificationGate)
        {
            if (_notificationsEnabled)
            {
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
            }
        }
    }

    protected void DisableNotifications()
    {
        lock (_notificationGate)
        {
            _notificationsEnabled = false;
        }
    }
}
